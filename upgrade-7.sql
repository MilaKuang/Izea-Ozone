-- Repack Ledger update 7: ask a computer to fill in Card Ladder values from the app.
-- Run once in Supabase: SQL Editor > New query > paste > Run. Safe to run more than once.

-- one row: the latest Card Ladder request and how the pricer computer is doing
create table if not exists public.pricer (
  id            int primary key default 1 check (id = 1),
  status        text not null default 'idle' check (status in ('idle', 'pending', 'working', 'done', 'error')),
  scope         text not null default 'missing' check (scope in ('missing', 'all')),
  requested_by  text,
  requested_at  timestamptz,
  started_at    timestamptz,
  finished_at   timestamptz,
  progress      int not null default 0,
  total         int not null default 0,
  current_card  text,
  message       text,
  result        jsonb,
  worker        text,
  last_seen     timestamptz
);
insert into public.pricer (id) values (1) on conflict (id) do nothing;

alter table public.pricer enable row level security;
drop policy if exists pricer_all on public.pricer;
create policy pricer_all on public.pricer for all using (public.is_member()) with check (public.is_member());
grant select, update on public.pricer to authenticated;
