-- Repack Ledger update 3: profile photos and the PSA lookup cache.
-- Run once in Supabase: SQL Editor > New query > paste > Run. Safe to run more than once.

-- ============ profile photos ============
alter table public.members add column if not exists avatar_path text;

create or replace function public.set_my_avatar(p_path text) returns text
language plpgsql security definer set search_path = public as $$
declare old text;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  if p_path is not null and p_path !~ '^avatars/[A-Za-z0-9_-]+\.jpg$' then raise exception 'bad photo path'; end if;
  select avatar_path into old from public.members where email = lower(coalesce(auth.jwt() ->> 'email', ''));
  update public.members set avatar_path = p_path where email = lower(coalesce(auth.jwt() ->> 'email', ''));
  return old;
end $$;
revoke execute on function public.set_my_avatar(text) from public, anon;
grant execute on function public.set_my_avatar(text) to authenticated;

-- ============ PSA lookup cache (saves your 100 free PSA calls a day) ============
create table if not exists public.psa_cache (
  cert       text primary key,
  info       jsonb not null,
  images     jsonb,
  fetched_at timestamptz not null default now()
);
alter table public.psa_cache enable row level security;
drop policy if exists psa_cache_all on public.psa_cache;
create policy psa_cache_all on public.psa_cache for all using (public.is_member()) with check (public.is_member());

-- live updates when someone changes their photo
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'members') then
    alter publication supabase_realtime add table public.members;
  end if;
end $$;
