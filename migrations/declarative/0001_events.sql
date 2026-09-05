    create extension if not exists pgcrypto;

    create table if not exists events (
        id uuid primary key default gen_random_uuid(),
        title text not null check (length(title) between 1 and 256),
        summary text not null default '' check (length(summary) <= 4000),
        source text not null,
venue text not null,
starts_at timestamptz not null,
source_url text not null,
        status text not null default 'draft',
        created_at timestamptz not null default now(),
        updated_at timestamptz not null default now()
    );

    create index if not exists events_status_created_idx
      on events(status, created_at desc, id);

    alter table events enable row level security;

    -- Production must replace this deny-by-default baseline with explicit
    -- tenant-scoped policies tied to authenticated subjects.
    drop policy if exists deny_anon_events on events;
    create policy deny_anon_events on events
      for all to anon using (false) with check (false);
