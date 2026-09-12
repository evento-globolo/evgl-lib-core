do $$
begin
    perform pg_advisory_xact_lock(3465001);
    create extension if not exists pgcrypto;
end;
$$;

create table if not exists admission_entitlements (
    ticket_id uuid primary key default gen_random_uuid(),
    order_id uuid not null references ticket_orders(id),
    event_id uuid not null references event_inventory(event_id),
    issuance_epoch bigint not null default 0 check (issuance_epoch >= 0),
    status text not null default 'active'
        check (status in ('active', 'refunded', 'revoked')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists admission_entitlements_order_idx
    on admission_entitlements(order_id, ticket_id);

create table if not exists admission_signing_keys (
    key_id text primary key check (length(key_id) between 1 and 120),
    issuance_epoch bigint not null check (issuance_epoch >= 0),
    public_key bytea not null check (octet_length(public_key) = 32),
    active_from timestamptz not null,
    retire_at timestamptz not null,
    created_at timestamptz not null default now(),
    check (retire_at > active_from)
);

create table if not exists admission_tokens (
    token_id uuid primary key,
    ticket_id uuid not null references admission_entitlements(ticket_id),
    order_id uuid not null references ticket_orders(id),
    event_id uuid not null references event_inventory(event_id),
    issuance_epoch bigint not null check (issuance_epoch >= 0),
    key_id text not null references admission_signing_keys(key_id),
    issued_at timestamptz not null,
    expires_at timestamptz not null,
    revoked_at timestamptz,
    created_at timestamptz not null default now(),
    check (expires_at > issued_at),
    check (revoked_at is null or revoked_at >= issued_at)
);

create index if not exists admission_tokens_ticket_idx
    on admission_tokens(ticket_id, issued_at desc);

create table if not exists admission_scanner_keys (
    scanner_id uuid not null,
    key_id text not null check (length(key_id) between 1 and 120),
    public_key bytea not null check (octet_length(public_key) = 32),
    active_from timestamptz not null,
    retire_at timestamptz not null,
    created_at timestamptz not null default now(),
    primary key (scanner_id, key_id),
    check (retire_at > active_from)
);

create table if not exists admission_scan_receipts (
    receipt_id uuid primary key,
    scanner_id uuid not null,
    scanner_key_id text not null,
    scanner_sequence bigint not null check (scanner_sequence >= 0),
    token_id uuid not null references admission_tokens(token_id),
    event_id uuid not null references event_inventory(event_id),
    ticket_id uuid not null references admission_entitlements(ticket_id),
    order_id uuid not null references ticket_orders(id),
    scanned_at timestamptz not null,
    received_at timestamptz not null,
    payload_hash bytea not null check (octet_length(payload_hash) = 32),
    signature bytea not null check (octet_length(signature) = 64),
    validation_status text not null
        check (validation_status in ('candidate', 'rejected')),
    validation_reason text,
    sequence_out_of_order boolean not null default false,
    unique (scanner_id, scanner_sequence),
    foreign key (scanner_id, scanner_key_id)
        references admission_scanner_keys(scanner_id, key_id)
);

create index if not exists admission_scan_receipts_ticket_idx
    on admission_scan_receipts(ticket_id, scanned_at, scanner_id, scanner_sequence);

create table if not exists admission_decisions (
    ticket_id uuid primary key references admission_entitlements(ticket_id),
    event_id uuid not null references event_inventory(event_id),
    winning_receipt_id uuid not null references admission_scan_receipts(receipt_id),
    decided_at timestamptz not null,
    candidate_count bigint not null check (candidate_count > 0)
);

create or replace function evgl_reconcile_ticket_admission(
    p_ticket_id uuid,
    p_received_at timestamptz
)
returns uuid
language plpgsql
as $$
declare
    winning_receipt admission_scan_receipts%rowtype;
    candidates bigint;
begin
    select receipt.* into winning_receipt
      from admission_scan_receipts receipt
      join admission_tokens token on token.token_id = receipt.token_id
      join admission_entitlements entitlement
        on entitlement.ticket_id = receipt.ticket_id
     where receipt.ticket_id = p_ticket_id
       and receipt.validation_status = 'candidate'
       and token.ticket_id = receipt.ticket_id
       and token.order_id = receipt.order_id
       and token.event_id = receipt.event_id
       and token.revoked_at is null
       and receipt.scanned_at >= token.issued_at
       and receipt.scanned_at < token.expires_at
       and entitlement.status = 'active'
       and entitlement.event_id = receipt.event_id
       and entitlement.order_id = receipt.order_id
       and entitlement.issuance_epoch = token.issuance_epoch
     order by receipt.scanned_at,
              receipt.scanner_id,
              receipt.scanner_sequence,
              receipt.receipt_id
     limit 1;

    if not found then
        delete from admission_decisions where ticket_id = p_ticket_id;
        return null;
    end if;

    select count(*) into candidates
      from admission_scan_receipts receipt
      join admission_tokens token on token.token_id = receipt.token_id
      join admission_entitlements entitlement
        on entitlement.ticket_id = receipt.ticket_id
     where receipt.ticket_id = p_ticket_id
       and receipt.validation_status = 'candidate'
       and token.ticket_id = receipt.ticket_id
       and token.order_id = receipt.order_id
       and token.event_id = receipt.event_id
       and token.revoked_at is null
       and receipt.scanned_at >= token.issued_at
       and receipt.scanned_at < token.expires_at
       and entitlement.status = 'active'
       and entitlement.event_id = receipt.event_id
       and entitlement.order_id = receipt.order_id
       and entitlement.issuance_epoch = token.issuance_epoch;

    insert into admission_decisions (
        ticket_id, event_id, winning_receipt_id, decided_at, candidate_count
    ) values (
        p_ticket_id,
        winning_receipt.event_id,
        winning_receipt.receipt_id,
        p_received_at,
        candidates
    ) on conflict (ticket_id) do update
      set event_id = excluded.event_id,
          winning_receipt_id = excluded.winning_receipt_id,
          decided_at = excluded.decided_at,
          candidate_count = excluded.candidate_count;

    return winning_receipt.receipt_id;
end;
$$;

create or replace function evgl_record_admission_receipt(
    p_receipt_id uuid,
    p_scanner_id uuid,
    p_scanner_key_id text,
    p_scanner_sequence bigint,
    p_token_id uuid,
    p_event_id uuid,
    p_ticket_id uuid,
    p_order_id uuid,
    p_scanned_at timestamptz,
    p_received_at timestamptz,
    p_payload_hash bytea,
    p_signature bytea,
    p_validation_status text,
    p_validation_reason text
)
returns uuid
language plpgsql
as $$
declare
    existing_receipt admission_scan_receipts%rowtype;
    sequence_out_of_order boolean;
begin
    perform pg_advisory_xact_lock(hashtextextended(p_scanner_id::text, 3465));
    select * into existing_receipt
      from admission_scan_receipts
     where scanner_id = p_scanner_id and scanner_sequence = p_scanner_sequence;
    if found then
        if existing_receipt.payload_hash <> p_payload_hash
           or existing_receipt.signature <> p_signature then
            raise exception 'EVGL_SCANNER_SEQUENCE_CONFLICT' using errcode = '22023';
        end if;
        return existing_receipt.receipt_id;
    end if;

    select p_scanner_sequence < coalesce(max(scanner_sequence), p_scanner_sequence)
      into sequence_out_of_order
      from admission_scan_receipts
     where scanner_id = p_scanner_id;

    if p_validation_status not in ('candidate', 'rejected') then
        raise exception 'EVGL_INVALID_RECEIPT_STATUS' using errcode = '22023';
    end if;

    insert into admission_scan_receipts (
        receipt_id, scanner_id, scanner_key_id, scanner_sequence,
        token_id, event_id, ticket_id, order_id, scanned_at, received_at,
        payload_hash, signature, validation_status, validation_reason,
        sequence_out_of_order
    ) values (
        p_receipt_id, p_scanner_id, p_scanner_key_id, p_scanner_sequence,
        p_token_id, p_event_id, p_ticket_id, p_order_id, p_scanned_at, p_received_at,
        p_payload_hash, p_signature, p_validation_status, p_validation_reason,
        sequence_out_of_order
    );

    perform evgl_reconcile_ticket_admission(p_ticket_id, p_received_at);
    return p_receipt_id;
end;
$$;

create or replace function evgl_revoke_admission_entitlement(
    p_ticket_id uuid,
    p_revoked_at timestamptz
)
returns bigint
language plpgsql
as $$
declare
    next_epoch bigint;
begin
    perform pg_advisory_xact_lock(hashtextextended(p_ticket_id::text, 3465));
    update admission_entitlements
       set status = 'revoked',
           issuance_epoch = issuance_epoch + 1,
           updated_at = p_revoked_at
     where ticket_id = p_ticket_id and status = 'active'
     returning issuance_epoch into next_epoch;
    if not found then
        select issuance_epoch into next_epoch
          from admission_entitlements where ticket_id = p_ticket_id;
    end if;
    if next_epoch is null then
        raise exception 'EVGL_ENTITLEMENT_NOT_FOUND' using errcode = 'P0002';
    end if;

    update admission_tokens
       set revoked_at = p_revoked_at
     where ticket_id = p_ticket_id and revoked_at is null;
    perform evgl_reconcile_ticket_admission(p_ticket_id, p_revoked_at);
    return next_epoch;
end;
$$;

create or replace view admission_receipt_outcomes as
select
    receipt.receipt_id,
    receipt.ticket_id,
    case
        when receipt.validation_status = 'rejected' then 'rejected'
        when decision.winning_receipt_id = receipt.receipt_id then 'accepted'
        when decision.winning_receipt_id is not null then 'duplicate_review'
        else 'rejected'
    end as outcome,
    case
        when receipt.validation_status = 'rejected' then receipt.validation_reason
        when decision.winning_receipt_id <> receipt.receipt_id then 'duplicate admission receipt'
        else null
    end as reason,
    decision.winning_receipt_id
from admission_scan_receipts receipt
left join admission_decisions decision on decision.ticket_id = receipt.ticket_id;
