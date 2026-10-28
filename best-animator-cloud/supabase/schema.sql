-- BEST Animator Cloud v0.3 (execute ONCE in Supabase SQL editor)
-- Roles: owner / manager / animator. No public data access.
create extension if not exists pgcrypto;

create table if not exists public.staff_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('owner','manager','animator')),
  created_at timestamptz not null default now()
);
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  phone text not null check (length(trim(phone)) > 0),
  source text not null default 'Instagram',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete restrict,
  program text not null,
  event_date date not null,
  start_time time not null,
  duration_minutes integer not null check(duration_minutes between 15 and 480),
  price_uzs bigint not null check(price_uzs > 0),
  status text not null default 'pending' check(status in ('lead','pending','confirmed','done','cancelled')),
  staff text not null default '',
  costume text not null default '',
  location text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  amount_uzs bigint not null check(amount_uzs > 0),
  payment_date date not null,
  kind text not null check(kind in ('payment','refund')),
  note text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create index if not exists orders_date_idx on public.orders(event_date,start_time);
create index if not exists orders_client_idx on public.orders(client_id);
create index if not exists payments_order_idx on public.payments(order_id);

create or replace function public.crm_role()
returns text language sql stable security definer set search_path = '' as $$
  select p.role from public.staff_profiles p where p.user_id = (select auth.uid());
$$;
revoke all on function public.crm_role() from public, anon;
grant execute on function public.crm_role() to authenticated;

alter table public.staff_profiles enable row level security;
alter table public.clients enable row level security;
alter table public.orders enable row level security;
alter table public.payments enable row level security;
revoke all on public.staff_profiles, public.clients, public.orders, public.payments from anon;
revoke all on public.staff_profiles, public.clients, public.orders, public.payments from authenticated;
grant select on public.staff_profiles to authenticated;
grant select,insert,update on public.clients,public.orders,public.payments to authenticated;

create policy "staff can read profile" on public.staff_profiles
for select to authenticated using (user_id = (select auth.uid()) or (select public.crm_role())='owner');
create policy "staff reads clients" on public.clients
for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
create policy "staff adds clients" on public.clients
for insert to authenticated with check ((select public.crm_role()) in ('owner','manager') and created_by=(select auth.uid()));
create policy "staff edits clients" on public.clients
for update to authenticated using ((select public.crm_role()) in ('owner','manager')) with check ((select public.crm_role()) in ('owner','manager'));
create policy "staff reads orders" on public.orders
for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
create policy "staff adds orders" on public.orders
for insert to authenticated with check ((select public.crm_role()) in ('owner','manager') and created_by=(select auth.uid()));
create policy "staff edits orders" on public.orders
for update to authenticated using ((select public.crm_role()) in ('owner','manager')) with check ((select public.crm_role()) in ('owner','manager'));
create policy "staff reads payments" on public.payments
for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
create policy "staff adds payments" on public.payments
for insert to authenticated with check ((select public.crm_role()) in ('owner','manager') and created_by=(select auth.uid()));
-- Ledger operations immutable: no UPDATE/DELETE policy. Refunds must be new rows.

-- INITIAL ACCESS after creating user in Supabase Authentication > Users:
-- replace email with YOUR registered email, run separately ONCE:
-- insert into public.staff_profiles(user_id, display_name, role)
-- select id, 'Владелец', 'owner' from auth.users where email='YOUR_EMAIL@example.com';
-- To add manager: create user in Authentication > Users, then insert row similarly with role 'manager'.
-- Disable public signups in Supabase Auth settings after creating staff accounts.
