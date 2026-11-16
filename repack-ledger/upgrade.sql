-- Upgrade 1: trades, sale details and photos.
-- Run this ONCE in the Supabase SQL Editor if you already ran the first setup.sql.
-- (If you have not run any SQL yet, skip this file: setup.sql already includes it.)

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
