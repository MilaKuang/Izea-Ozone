-- Repack Ledger database setup for Supabase.
-- Run this whole file once in: Supabase dashboard > SQL Editor > New query.
-- BEFORE running, change the three emails in the "members" insert below to the
-- real emails of Izea, Mila and Alex (lowercase). Only these emails get access.

-- ============ access list ============
create table public.members (
  email text primary key check (email = lower(email)),
  name  text not null
);

insert into public.members (email, name) values
  ('izea@example.com', 'Izea'),
  ('mila@example.com', 'Mila'),
  ('alex@example.com', 'Alex');

create function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create function public.my_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from public.members
                   where email = lower(coalesce(auth.jwt() ->> 'email', ''))), 'Unknown');
$$;

-- ============ tables ============
create table public.settings (
  id          int primary key default 1 check (id = 1),
  partners    jsonb not null default '["Izea","Ozone"]',
  reset_day   int   not null default 1 check (reset_day between 0 and 6),
  default_pct numeric(5,2) not null default 90
);
insert into public.settings (id) values (1);

create table public.weeks (
  id         uuid primary key default gen_random_uuid(),
  label      text,
  start_date date not null default ((now() at time zone 'America/Los_Angeles')::date),
  end_date   date,
  closed     boolean not null default false,
  closed_by  text,
  created_at timestamptz not null default now()
);
create unique index one_open_week on public.weeks (closed) where closed = false;
insert into public.weeks (label) values ('Current week');

create table public.cards (
  seq            bigint generated always as identity,
  id             uuid primary key default gen_random_uuid(),
  week_id        uuid not null references public.weeks(id) on delete cascade,
  date_purchased date default ((now() at time zone 'America/Los_Angeles')::date),
  cert           text,
  description    text not null default '',
  owner          text not null default 'Shared',
  market_value   numeric(12,2),
  consignor_pct  numeric(5,2) not null default 90,
  sold           boolean not null default false,
  sold_price     numeric(12,2),
  sold_date      date,
  split_done     boolean not null default false,
  notes          text not null default '',
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_by     text,
  updated_at     timestamptz not null default now(),
  unique (week_id, cert)
);
create index cards_week on public.cards (week_id);

create table public.spend (
  seq        bigint generated always as identity,
  id         uuid primary key default gen_random_uuid(),
  week_id    uuid not null references public.weeks(id) on delete cascade,
  partner    text not null,
  amount     numeric(12,2) not null,
  entry_date date not null default ((now() at time zone 'America/Los_Angeles')::date),
  note       text not null default '',
  created_by text,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now()
);
create index spend_week on public.spend (week_id);

create table public.payouts (
  seq        bigint generated always as identity,
  id         uuid primary key default gen_random_uuid(),
  week_id    uuid not null references public.weeks(id) on delete cascade,
  partner    text not null,
  amount     numeric(12,2) not null,
  entry_date date not null default ((now() at time zone 'America/Los_Angeles')::date),
  note       text not null default '',
  card_id    uuid references public.cards(id) on delete set null,
  created_by text,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now(),
  unique (card_id, partner)
);
create index payouts_week on public.payouts (week_id);

create table public.audit (
  id        bigint generated always as identity primary key,
  ts        timestamptz not null default now(),
  user_name text not null,
  action    text not null,
  entity    text not null,
  item      text,
  detail    text
);

-- ============ who added / edited (set by the database, cannot be faked) ============
create function public.stamp_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare n text := public.my_name();
begin
  if tg_op = 'INSERT' then
    new.created_by := n;
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_by := n;
  new.updated_at := now();
  return new;
end $$;

create trigger a_stamp before insert or update on public.cards   for each row execute function public.stamp_row();
create trigger a_stamp before insert or update on public.spend   for each row execute function public.stamp_row();
create trigger a_stamp before insert or update on public.payouts for each row execute function public.stamp_row();

-- ============ activity log (written by the database, clients cannot edit it) ============
create function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n text := public.my_name();
  r jsonb;
  o jsonb;
  k text;
  item text;
  det text;
begin
  if current_setting('app.skip_audit', true) = '1' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op = 'DELETE' then r := to_jsonb(old); else r := to_jsonb(new); end if;

  item := case tg_table_name
    when 'cards'    then coalesce(nullif(r ->> 'description', ''), '(no description)')
                         || coalesce(' | cert ' || nullif(r ->> 'cert', ''), '')
    when 'weeks'    then coalesce(r ->> 'label', 'Week')
    when 'settings' then 'settings'
    else (r ->> 'partner') || ' $' || (r ->> 'amount')
  end;

  if tg_op = 'UPDATE' then
    o := to_jsonb(old);
    for k in select jsonb_object_keys(r) loop
      if k not in ('updated_at', 'updated_by', 'created_at', 'created_by')
         and (r -> k) is distinct from (o -> k) then
        det := concat_ws('; ', det, k || ': ' || coalesce(o ->> k, 'blank') || ' -> ' || coalesce(r ->> k, 'blank'));
      end if;
    end loop;
    if det is null then return new; end if;
  elsif tg_op = 'INSERT' and tg_table_name in ('spend', 'payouts') then
    det := nullif(r ->> 'note', '');
  end if;

  insert into public.audit (user_name, action, entity, item, detail)
  values (n, lower(tg_op), tg_table_name, item, det);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger z_audit after insert or update or delete on public.cards    for each row execute function public.audit_row();
create trigger z_audit after insert or update or delete on public.spend    for each row execute function public.audit_row();
create trigger z_audit after insert or update or delete on public.payouts  for each row execute function public.audit_row();
create trigger z_audit after insert or update or delete on public.weeks    for each row execute function public.audit_row();
create trigger z_audit after update                     on public.settings for each row execute function public.audit_row();

-- ============ security: only people on the members list can read or write ============
alter table public.members  enable row level security;
alter table public.settings enable row level security;
alter table public.weeks    enable row level security;
alter table public.cards    enable row level security;
alter table public.spend    enable row level security;
alter table public.payouts  enable row level security;
alter table public.audit    enable row level security;

create policy members_read on public.members for select using (public.is_member());
create policy settings_all on public.settings for all using (public.is_member()) with check (public.is_member());
create policy weeks_all    on public.weeks    for all using (public.is_member()) with check (public.is_member());
create policy cards_all    on public.cards    for all using (public.is_member()) with check (public.is_member());
create policy spend_all    on public.spend    for all using (public.is_member()) with check (public.is_member());
create policy payouts_all  on public.payouts  for all using (public.is_member()) with check (public.is_member());
create policy audit_read   on public.audit    for select using (public.is_member());
-- no insert/update/delete policy on audit: only the triggers above can write to it

-- ============ actions that must be atomic ============
create function public.close_week(p_label text, p_carry boolean default false) returns uuid
language plpgsql as $$
declare
  old_id uuid;
  new_id uuid;
  today  date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  select id into old_id from public.weeks where closed = false for update;
  if old_id is null then raise exception 'no open week'; end if;

  update public.weeks
     set closed = true,
         end_date = today,
         closed_by = public.my_name(),
         label = coalesce(nullif(p_label, ''),
                          'Week of ' || to_char(start_date, 'MM/DD/YYYY') || ' - ' || to_char(today, 'MM/DD/YYYY'))
   where id = old_id;

  insert into public.weeks (start_date) values (today) returning id into new_id;

  if p_carry then
    insert into public.cards (week_id, date_purchased, cert, description, owner, market_value, consignor_pct, notes)
    select new_id, date_purchased, cert, description, owner, market_value, consignor_pct, notes
      from public.cards where week_id = old_id and not sold;
  end if;
  return new_id;
end $$;

create function public.save_settings(p_partners jsonb, p_reset_day int, p_default_pct numeric) returns void
language plpgsql as $$
declare old jsonb;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  select partners into old from public.settings where id = 1;
  perform set_config('app.skip_audit', '1', true);  -- renames are logged once, on settings
  -- rename partners everywhere (two phases so a swap cannot collide)
  for i in 0..1 loop
    if (old ->> i) is distinct from (p_partners ->> i) then
      update public.cards   set owner   = '~~' || i where owner   = old ->> i;
      update public.spend   set partner = '~~' || i where partner = old ->> i;
      update public.payouts set partner = '~~' || i where partner = old ->> i;
    end if;
  end loop;
  for i in 0..1 loop
    if (old ->> i) is distinct from (p_partners ->> i) then
      update public.cards   set owner   = p_partners ->> i where owner   = '~~' || i;
      update public.spend   set partner = p_partners ->> i where partner = '~~' || i;
      update public.payouts set partner = p_partners ->> i where partner = '~~' || i;
    end if;
  end loop;
  perform set_config('app.skip_audit', '0', true);
  update public.settings
     set partners = p_partners, reset_day = p_reset_day, default_pct = p_default_pct
   where id = 1;
end $$;

-- ============ live updates between phones ============
alter publication supabase_realtime add table
  public.cards, public.spend, public.payouts, public.weeks, public.settings;

-- ============ trades, sale details and photos ============
-- ============ how a card left inventory, and trade details ============
alter table public.cards
  add column if not exists sale_type text check (sale_type in ('sold', 'traded')),
  add column if not exists trade_cash numeric(12,2),
  add column if not exists from_card_id uuid references public.cards(id) on delete set null;

update public.cards set sale_type = 'sold' where sold and sale_type is null;

-- ============ photos of buys, trades, sales and payouts ============
create table if not exists public.attachments (
  id         uuid primary key default gen_random_uuid(),
  card_id    uuid references public.cards(id)   on delete cascade,
  spend_id   uuid references public.spend(id)   on delete cascade,
  payout_id  uuid references public.payouts(id) on delete cascade,
  path       text not null unique,
  caption    text not null default '',
  created_by text,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now(),
  check (num_nonnulls(card_id, spend_id, payout_id) = 1)
);
create index if not exists attachments_card   on public.attachments (card_id);
create index if not exists attachments_spend  on public.attachments (spend_id);
create index if not exists attachments_payout on public.attachments (payout_id);

alter table public.attachments enable row level security;
create policy attachments_all on public.attachments for all using (public.is_member()) with check (public.is_member());

create trigger a_stamp before insert or update on public.attachments for each row execute function public.stamp_row();

-- activity log: describe photos by what they are attached to
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n text := public.my_name();
  r jsonb;
  o jsonb;
  k text;
  item text;
  det text;
begin
  if current_setting('app.skip_audit', true) = '1' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op = 'DELETE' then r := to_jsonb(old); else r := to_jsonb(new); end if;

  item := case tg_table_name
    when 'cards'    then coalesce(nullif(r ->> 'description', ''), '(no description)')
                         || coalesce(' | cert ' || nullif(r ->> 'cert', ''), '')
    when 'weeks'    then coalesce(r ->> 'label', 'Week')
    when 'settings' then 'settings'
    when 'attachments' then 'photo on ' || coalesce(
        (select coalesce(nullif(c.description, ''), 'cert ' || c.cert, 'card') from public.cards c where c.id = (r ->> 'card_id')::uuid),
        (select s.partner || ' $' || s.amount from public.spend s where s.id = (r ->> 'spend_id')::uuid),
        (select p.partner || ' $' || p.amount from public.payouts p where p.id = (r ->> 'payout_id')::uuid),
        'an entry')
    else (r ->> 'partner') || ' $' || (r ->> 'amount')
  end;

  if tg_op = 'UPDATE' then
    o := to_jsonb(old);
    for k in select jsonb_object_keys(r) loop
      if k not in ('updated_at', 'updated_by', 'created_at', 'created_by')
         and (r -> k) is distinct from (o -> k) then
        det := concat_ws('; ', det, k || ': ' || coalesce(o ->> k, 'blank') || ' -> ' || coalesce(r ->> k, 'blank'));
      end if;
    end loop;
    if det is null then return new; end if;
  elsif tg_op = 'INSERT' and tg_table_name in ('spend', 'payouts') then
    det := nullif(r ->> 'note', '');
  end if;

  insert into public.audit (user_name, action, entity, item, detail)
  values (n, lower(tg_op), tg_table_name, item, det);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger z_audit after insert or delete on public.attachments for each row execute function public.audit_row();

-- ============ private photo storage (members only) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy receipts_read   on storage.objects for select using (bucket_id = 'receipts' and public.is_member());
create policy receipts_insert on storage.objects for insert with check (bucket_id = 'receipts' and public.is_member());
create policy receipts_delete on storage.objects for delete using (bucket_id = 'receipts' and public.is_member());

alter publication supabase_realtime add table public.attachments;
