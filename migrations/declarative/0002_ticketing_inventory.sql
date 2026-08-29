do $$
begin
    perform pg_advisory_xact_lock(3464001);
    create extension if not exists pgcrypto;
end;
$$;

create table if not exists event_inventory (
    event_id uuid primary key,
    capacity integer not null check (capacity > 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists ticket_classes (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references event_inventory(event_id),
    name text not null check (length(name) between 1 and 120),
    capacity integer not null check (capacity > 0),
    sale_starts_at timestamptz not null,
    sale_ends_at timestamptz not null,
    created_at timestamptz not null default now(),
    unique (event_id, name),
    check (sale_ends_at > sale_starts_at)
);

create table if not exists ticket_holds (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references event_inventory(event_id),
    ticket_class_id uuid not null references ticket_classes(id),
    quantity integer not null check (quantity > 0),
    idempotency_key text not null check (length(idempotency_key) between 1 and 200),
    status text not null default 'held'
        check (status in ('held', 'converted', 'expired', 'cancelled')),
    expires_at timestamptz not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (event_id, idempotency_key)
);

create index if not exists ticket_holds_live_inventory_idx
    on ticket_holds(event_id, ticket_class_id, expires_at)
    where status = 'held';

create table if not exists ticket_orders (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references event_inventory(event_id),
    ticket_class_id uuid not null references ticket_classes(id),
    hold_id uuid not null unique references ticket_holds(id),
    quantity integer not null check (quantity > 0),
    checkout_idempotency_key text not null unique
        check (length(checkout_idempotency_key) between 1 and 200),
    payment_idempotency_key text unique,
    status text not null default 'pending'
        check (status in ('pending', 'paid', 'cancelled', 'refunded')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists ticket_orders_paid_inventory_idx
    on ticket_orders(event_id, ticket_class_id)
    where status = 'paid';

create table if not exists ticket_order_history (
    sequence bigint generated always as identity primary key,
    order_id uuid not null references ticket_orders(id),
    event_type text not null,
    idempotency_key text not null,
    occurred_at timestamptz not null,
    details jsonb not null default '{}'::jsonb,
    unique (order_id, idempotency_key)
);

create table if not exists ticket_inventory_ledger (
    sequence bigint generated always as identity primary key,
    event_id uuid not null references event_inventory(event_id),
    ticket_class_id uuid not null references ticket_classes(id),
    hold_id uuid references ticket_holds(id),
    order_id uuid references ticket_orders(id),
    event_type text not null,
    quantity_delta integer not null,
    idempotency_key text not null,
    occurred_at timestamptz not null,
    unique (event_id, idempotency_key)
);

create table if not exists ticket_waitlist (
    id uuid primary key default gen_random_uuid(),
    event_id uuid not null references event_inventory(event_id),
    ticket_class_id uuid not null references ticket_classes(id),
    attendee_ref_hash text not null check (length(attendee_ref_hash) between 32 and 128),
    quantity integer not null check (quantity > 0),
    position bigint generated always as identity,
    status text not null default 'waiting'
        check (status in ('waiting', 'offered', 'fulfilled', 'cancelled')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (event_id, ticket_class_id, attendee_ref_hash)
);

create index if not exists ticket_waitlist_fairness_idx
    on ticket_waitlist(event_id, ticket_class_id, position)
    where status = 'waiting';

create table if not exists ticket_waitlist_offers (
    id uuid primary key default gen_random_uuid(),
    waitlist_entry_id uuid not null references ticket_waitlist(id),
    hold_id uuid not null unique references ticket_holds(id),
    status text not null default 'active'
        check (status in ('active', 'accepted', 'expired', 'cancelled')),
    expires_at timestamptz not null,
    created_at timestamptz not null default now()
);

create unique index if not exists ticket_waitlist_one_active_offer_idx
    on ticket_waitlist_offers(waitlist_entry_id)
    where status = 'active';

create or replace function evgl_expire_ticket_holds(
    p_now timestamptz,
    p_event_id uuid default null
)
returns bigint
language plpgsql
as $$
declare
    expired_hold record;
    expired_count bigint := 0;
begin
    for expired_hold in
        update ticket_holds
           set status = 'expired', updated_at = p_now
         where status = 'held'
           and expires_at <= p_now
           and (p_event_id is null or event_id = p_event_id)
         returning id, event_id, ticket_class_id, quantity
    loop
        insert into ticket_inventory_ledger (
            event_id, ticket_class_id, hold_id, event_type,
            quantity_delta, idempotency_key, occurred_at
        ) values (
            expired_hold.event_id,
            expired_hold.ticket_class_id,
            expired_hold.id,
            'hold_expired',
            expired_hold.quantity,
            'expire:' || expired_hold.id::text,
            p_now
        ) on conflict (event_id, idempotency_key) do nothing;

        update ticket_waitlist_offers
           set status = 'expired'
         where hold_id = expired_hold.id and status = 'active';

        update ticket_waitlist
           set status = 'waiting', updated_at = p_now
         where id in (
             select waitlist_entry_id
               from ticket_waitlist_offers
              where hold_id = expired_hold.id and status = 'expired'
         ) and status = 'offered';

        expired_count := expired_count + 1;
    end loop;

    return expired_count;
end;
$$;

create or replace function evgl_reserve_tickets(
    p_event_id uuid,
    p_ticket_class_id uuid,
    p_quantity integer,
    p_idempotency_key text,
    p_now timestamptz,
    p_expires_at timestamptz
)
returns uuid
language plpgsql
as $$
declare
    existing_hold ticket_holds%rowtype;
    event_capacity integer;
    class_capacity integer;
    sale_start timestamptz;
    sale_end timestamptz;
    event_used bigint;
    class_used bigint;
    new_hold_id uuid;
begin
    if p_quantity <= 0 then
        raise exception 'EVGL_INVALID_QUANTITY' using errcode = '22023';
    end if;
    if p_expires_at <= p_now then
        raise exception 'EVGL_INVALID_HOLD_EXPIRY' using errcode = '22023';
    end if;

    select * into existing_hold
      from ticket_holds
     where event_id = p_event_id and idempotency_key = p_idempotency_key;
    if found then
        if existing_hold.ticket_class_id <> p_ticket_class_id
           or existing_hold.quantity <> p_quantity then
            raise exception 'EVGL_IDEMPOTENCY_CONFLICT' using errcode = '22023';
        end if;
        return existing_hold.id;
    end if;

    perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 3464));
    perform evgl_expire_ticket_holds(p_now, p_event_id);

    select inventory.capacity, class.capacity,
           class.sale_starts_at, class.sale_ends_at
      into event_capacity, class_capacity, sale_start, sale_end
      from ticket_classes class
      join event_inventory inventory on inventory.event_id = class.event_id
     where class.id = p_ticket_class_id and class.event_id = p_event_id
     for update of class, inventory;

    if not found then
        raise exception 'EVGL_TICKET_CLASS_NOT_FOUND' using errcode = 'P0002';
    end if;
    if p_now < sale_start or p_now >= sale_end then
        raise exception 'EVGL_SALE_WINDOW_CLOSED' using errcode = '22023';
    end if;

    select
        coalesce((select sum(quantity) from ticket_holds
                  where event_id = p_event_id and status = 'held' and expires_at > p_now), 0)
        + coalesce((select sum(quantity) from ticket_orders
                    where event_id = p_event_id and status = 'paid'), 0)
      into event_used;
    select
        coalesce((select sum(quantity) from ticket_holds
                  where ticket_class_id = p_ticket_class_id
                    and status = 'held' and expires_at > p_now), 0)
        + coalesce((select sum(quantity) from ticket_orders
                    where ticket_class_id = p_ticket_class_id and status = 'paid'), 0)
      into class_used;

    if event_used + p_quantity > event_capacity
       or class_used + p_quantity > class_capacity then
        raise exception 'EVGL_CAPACITY_EXCEEDED' using errcode = 'P0001';
    end if;

    insert into ticket_holds (
        event_id, ticket_class_id, quantity, idempotency_key,
        expires_at, created_at, updated_at
    ) values (
        p_event_id, p_ticket_class_id, p_quantity, p_idempotency_key,
        p_expires_at, p_now, p_now
    ) returning id into new_hold_id;

    insert into ticket_inventory_ledger (
        event_id, ticket_class_id, hold_id, event_type,
        quantity_delta, idempotency_key, occurred_at
    ) values (
        p_event_id, p_ticket_class_id, new_hold_id, 'hold_reserved',
        -p_quantity, 'reserve:' || p_idempotency_key, p_now
    );

    return new_hold_id;
end;
$$;

create or replace function evgl_create_ticket_order(
    p_hold_id uuid,
    p_checkout_idempotency_key text,
    p_now timestamptz
)
returns uuid
language plpgsql
as $$
declare
    existing_order ticket_orders%rowtype;
    selected_hold ticket_holds%rowtype;
    new_order_id uuid;
begin
    select * into existing_order
      from ticket_orders
     where checkout_idempotency_key = p_checkout_idempotency_key;
    if found then
        if existing_order.hold_id <> p_hold_id then
            raise exception 'EVGL_IDEMPOTENCY_CONFLICT' using errcode = '22023';
        end if;
        return existing_order.id;
    end if;

    select * into selected_hold from ticket_holds where id = p_hold_id for update;
    if not found then
        raise exception 'EVGL_HOLD_NOT_FOUND' using errcode = 'P0002';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(selected_hold.event_id::text, 3464));
    perform evgl_expire_ticket_holds(p_now, selected_hold.event_id);
    select * into selected_hold from ticket_holds where id = p_hold_id for update;
    if selected_hold.status <> 'held' or selected_hold.expires_at <= p_now then
        raise exception 'EVGL_HOLD_NOT_ACTIVE' using errcode = '22023';
    end if;

    insert into ticket_orders (
        event_id, ticket_class_id, hold_id, quantity,
        checkout_idempotency_key, created_at, updated_at
    ) values (
        selected_hold.event_id,
        selected_hold.ticket_class_id,
        selected_hold.id,
        selected_hold.quantity,
        p_checkout_idempotency_key,
        p_now,
        p_now
    ) returning id into new_order_id;

    insert into ticket_order_history (
        order_id, event_type, idempotency_key, occurred_at
    ) values (
        new_order_id, 'order_created', 'checkout:' || p_checkout_idempotency_key, p_now
    );

    return new_order_id;
end;
$$;

create or replace function evgl_confirm_ticket_payment(
    p_order_id uuid,
    p_payment_idempotency_key text,
    p_now timestamptz
)
returns uuid
language plpgsql
as $$
declare
    selected_order ticket_orders%rowtype;
    selected_hold ticket_holds%rowtype;
begin
    select * into selected_order
      from ticket_orders
     where payment_idempotency_key = p_payment_idempotency_key;
    if found then
        if selected_order.id <> p_order_id then
            raise exception 'EVGL_IDEMPOTENCY_CONFLICT' using errcode = '22023';
        end if;
        return selected_order.id;
    end if;

    select * into selected_order from ticket_orders where id = p_order_id for update;
    if not found then
        raise exception 'EVGL_ORDER_NOT_FOUND' using errcode = 'P0002';
    end if;
    if selected_order.status = 'paid' then
        return selected_order.id;
    end if;
    if selected_order.status <> 'pending' then
        raise exception 'EVGL_ORDER_NOT_PAYABLE' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(hashtextextended(selected_order.event_id::text, 3464));
    perform evgl_expire_ticket_holds(p_now, selected_order.event_id);
    select * into selected_hold
      from ticket_holds where id = selected_order.hold_id for update;
    if selected_hold.status <> 'held' or selected_hold.expires_at <= p_now then
        raise exception 'EVGL_HOLD_NOT_ACTIVE' using errcode = '22023';
    end if;

    update ticket_orders
       set status = 'paid',
           payment_idempotency_key = p_payment_idempotency_key,
           updated_at = p_now
     where id = p_order_id;
    update ticket_holds
       set status = 'converted', updated_at = p_now
     where id = selected_order.hold_id;

    insert into ticket_order_history (
        order_id, event_type, idempotency_key, occurred_at
    ) values (
        p_order_id, 'payment_confirmed',
        'payment:' || p_payment_idempotency_key, p_now
    );
    insert into ticket_inventory_ledger (
        event_id, ticket_class_id, hold_id, order_id, event_type,
        quantity_delta, idempotency_key, occurred_at
    ) values (
        selected_order.event_id,
        selected_order.ticket_class_id,
        selected_order.hold_id,
        selected_order.id,
        'hold_converted',
        0,
        'payment:' || p_payment_idempotency_key,
        p_now
    );

    return p_order_id;
end;
$$;

create or replace function evgl_cancel_ticket_order(
    p_order_id uuid,
    p_cancellation_idempotency_key text,
    p_refund boolean,
    p_now timestamptz
)
returns uuid
language plpgsql
as $$
declare
    selected_order ticket_orders%rowtype;
    event_name text;
begin
    if exists (
        select 1 from ticket_order_history
         where order_id = p_order_id
           and idempotency_key = 'cancel:' || p_cancellation_idempotency_key
    ) then
        return p_order_id;
    end if;

    select * into selected_order from ticket_orders where id = p_order_id for update;
    if not found then
        raise exception 'EVGL_ORDER_NOT_FOUND' using errcode = 'P0002';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(selected_order.event_id::text, 3464));

    if selected_order.status in ('cancelled', 'refunded') then
        return selected_order.id;
    end if;

    event_name := case
        when p_refund and selected_order.status = 'paid' then 'order_refunded'
        else 'order_cancelled'
    end;

    update ticket_orders
       set status = case
               when p_refund and selected_order.status = 'paid' then 'refunded'
               else 'cancelled'
           end,
           updated_at = p_now
     where id = p_order_id;
    update ticket_holds
       set status = 'cancelled', updated_at = p_now
     where id = selected_order.hold_id and status = 'held';

    insert into ticket_order_history (
        order_id, event_type, idempotency_key, occurred_at
    ) values (
        p_order_id, event_name,
        'cancel:' || p_cancellation_idempotency_key, p_now
    );
    insert into ticket_inventory_ledger (
        event_id, ticket_class_id, hold_id, order_id, event_type,
        quantity_delta, idempotency_key, occurred_at
    ) values (
        selected_order.event_id,
        selected_order.ticket_class_id,
        selected_order.hold_id,
        selected_order.id,
        event_name,
        selected_order.quantity,
        'cancel:' || p_cancellation_idempotency_key,
        p_now
    );

    return p_order_id;
end;
$$;

create or replace function evgl_join_ticket_waitlist(
    p_event_id uuid,
    p_ticket_class_id uuid,
    p_attendee_ref_hash text,
    p_quantity integer,
    p_now timestamptz
)
returns uuid
language plpgsql
as $$
declare
    entry_id uuid;
begin
    insert into ticket_waitlist (
        event_id, ticket_class_id, attendee_ref_hash, quantity,
        created_at, updated_at
    ) values (
        p_event_id, p_ticket_class_id, p_attendee_ref_hash, p_quantity,
        p_now, p_now
    ) on conflict (event_id, ticket_class_id, attendee_ref_hash)
      do update set attendee_ref_hash = excluded.attendee_ref_hash
    returning id into entry_id;

    return entry_id;
end;
$$;

create or replace function evgl_promote_ticket_waitlist(
    p_event_id uuid,
    p_ticket_class_id uuid,
    p_now timestamptz,
    p_offer_expires_at timestamptz
)
returns uuid
language plpgsql
as $$
declare
    selected_entry ticket_waitlist%rowtype;
    promoted_hold_id uuid;
    offer_id uuid;
begin
    perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 3464));
    perform evgl_expire_ticket_holds(p_now, p_event_id);

    select * into selected_entry
      from ticket_waitlist
     where event_id = p_event_id
       and ticket_class_id = p_ticket_class_id
       and status = 'waiting'
     order by position
     for update skip locked
     limit 1;
    if not found then
        return null;
    end if;

    promoted_hold_id := evgl_reserve_tickets(
        p_event_id,
        p_ticket_class_id,
        selected_entry.quantity,
        'waitlist:' || selected_entry.id::text,
        p_now,
        p_offer_expires_at
    );

    insert into ticket_waitlist_offers (
        waitlist_entry_id, hold_id, expires_at, created_at
    ) values (
        selected_entry.id, promoted_hold_id, p_offer_expires_at, p_now
    ) returning id into offer_id;
    update ticket_waitlist
       set status = 'offered', updated_at = p_now
     where id = selected_entry.id;

    return offer_id;
end;
$$;

create or replace view ticket_inventory_receipts as
select
    inventory.event_id,
    inventory.capacity as event_capacity,
    coalesce(holds.held, 0)::bigint as held,
    coalesce(orders.sold, 0)::bigint as sold,
    greatest(
        inventory.capacity::bigint - coalesce(holds.held, 0) - coalesce(orders.sold, 0),
        0
    )::bigint as remaining
from event_inventory inventory
left join lateral (
    select sum(quantity)::bigint as held
      from ticket_holds
     where event_id = inventory.event_id
       and status = 'held'
       and expires_at > now()
) holds on true
left join lateral (
    select sum(quantity)::bigint as sold
      from ticket_orders
     where event_id = inventory.event_id and status = 'paid'
) orders on true;
