-- Apply AFTER v0.5, only once after backing up Supabase.
begin;
create table if not exists public.telegram_recipients (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(trim(name)) between 1 and 120),
 role text not null check (role in ('manager','animator')),
 team_id uuid references public.teams(id) on delete restrict,
 chat_id text not null check (chat_id ~ '^-?[0-9]+$'),
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 check ((role='manager' and team_id is null) or (role='animator' and team_id is not null)),
 unique(chat_id,team_id)
);
create table if not exists public.telegram_delivery_log (
 id bigint generated always as identity primary key,
 notification_date date not null,
 order_id uuid not null references public.orders(id) on delete cascade,
 recipient_id uuid not null references public.telegram_recipients(id) on delete cascade,
 sent_at timestamptz not null default now(),
 unique(notification_date,order_id,recipient_id)
);
alter table public.telegram_recipients enable row level security;
alter table public.telegram_delivery_log enable row level security;
revoke all on public.telegram_recipients,public.telegram_delivery_log from anon,authenticated;
grant select,insert,update on public.telegram_recipients to authenticated;
create policy "crm recipient read" on public.telegram_recipients for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
create policy "crm recipient insert" on public.telegram_recipients for insert to authenticated with check ((select public.crm_role()) in ('owner','manager'));
create policy "crm recipient update" on public.telegram_recipients for update to authenticated using ((select public.crm_role()) in ('owner','manager')) with check ((select public.crm_role()) in ('owner','manager'));
-- delivery_log is server-only, accessed by service role. No user access or policies.
commit;
