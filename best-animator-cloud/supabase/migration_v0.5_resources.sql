-- BEST Animator v0.5: RUN ONCE after v0.3; supersedes v0.4 global no-overlap trigger.
-- Before running: back up your database. Existing orders/payments remain untouched.
begin;
create table if not exists public.characters (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(btrim(name))>0),
 notes text not null default '',
 is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.teams (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(btrim(name))>0),
 notes text not null default '',
 is_active boolean not null default true,
 created_at timestamptz not null default now()
);
alter table public.orders add column if not exists team_id uuid references public.teams(id) on delete restrict;
create table if not exists public.order_characters (
 order_id uuid not null references public.orders(id) on delete restrict,
 character_id uuid not null references public.characters(id) on delete restrict,
 primary key (order_id,character_id)
);
create index if not exists order_characters_character_idx on public.order_characters(character_id);
create index if not exists orders_team_date_idx on public.orders(team_id,event_date);

alter table public.characters enable row level security;
alter table public.teams enable row level security;
alter table public.order_characters enable row level security;
revoke all on public.characters,public.teams,public.order_characters from anon;
revoke all on public.characters,public.teams,public.order_characters from authenticated;
grant select,insert,update on public.characters,public.teams to authenticated;
grant select,insert on public.order_characters to authenticated;

drop policy if exists "staff reads characters" on public.characters;
create policy "staff reads characters" on public.characters for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff manages characters" on public.characters;
create policy "staff manages characters" on public.characters for insert to authenticated with check ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff updates characters" on public.characters;
create policy "staff updates characters" on public.characters for update to authenticated using ((select public.crm_role()) in ('owner','manager')) with check ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff reads teams" on public.teams;
create policy "staff reads teams" on public.teams for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff manages teams" on public.teams;
create policy "staff manages teams" on public.teams for insert to authenticated with check ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff updates teams" on public.teams;
create policy "staff updates teams" on public.teams for update to authenticated using ((select public.crm_role()) in ('owner','manager')) with check ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff reads assignments" on public.order_characters;
create policy "staff reads assignments" on public.order_characters for select to authenticated using ((select public.crm_role()) in ('owner','manager'));
drop policy if exists "staff assigns characters" on public.order_characters;
create policy "staff assigns characters" on public.order_characters for insert to authenticated with check ((select public.crm_role()) in ('owner','manager'));

-- Replace company-wide blocker from v0.4 with team- and character-specific checks.
drop trigger if exists orders_no_overlap on public.orders;

create or replace function public.check_resource_order()
returns trigger language plpgsql set search_path = '' as $$
begin
 if (extract(epoch from NEW.start_time)/60 + NEW.duration_minutes)>1440 then
  raise exception 'BEST_ANIMATOR_EVENT_CROSSES_MIDNIGHT' using errcode='23514';
 end if;
 if NEW.status in ('cancelled','lead') then return NEW; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(NEW.event_date::text));
 if NEW.team_id is not null then
  if not exists(select 1 from public.teams t where t.id=NEW.team_id and t.is_active) then
   raise exception 'BEST_ANIMATOR_INACTIVE_TEAM' using errcode='23514';
  end if;
  if exists(select 1 from public.orders o
   where o.id<>NEW.id and o.team_id=NEW.team_id and o.event_date=NEW.event_date
   and o.status not in ('cancelled','lead')
   and o.start_time < NEW.start_time + NEW.duration_minutes * interval '1 minute'
   and NEW.start_time < o.start_time + o.duration_minutes * interval '1 minute') then
    raise exception 'BEST_ANIMATOR_TEAM_CONFLICT' using errcode='23P01';
  end if;
 end if;
 if exists(select 1 from public.order_characters oc
  join public.orders o on o.id=oc.order_id
  join public.order_characters oldoc on oldoc.character_id=oc.character_id and oldoc.order_id=NEW.id
  where o.id<>NEW.id and o.event_date=NEW.event_date and o.status not in ('cancelled','lead')
   and o.start_time < NEW.start_time + NEW.duration_minutes * interval '1 minute'
   and NEW.start_time < o.start_time + o.duration_minutes * interval '1 minute') then
    raise exception 'BEST_ANIMATOR_CHARACTER_CONFLICT' using errcode='23P01';
 end if;
 return NEW;
end $$;
drop trigger if exists orders_resource_check on public.orders;
create trigger orders_resource_check before insert or update of team_id,event_date,start_time,duration_minutes,status
on public.orders for each row execute function public.check_resource_order();

create or replace function public.check_character_assignment()
returns trigger language plpgsql set search_path = '' as $$
declare booking public.orders%rowtype;
begin
 select * into booking from public.orders where id=NEW.order_id;
 if not found then raise exception 'BEST_ANIMATOR_ORDER_NOT_FOUND'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(booking.event_date::text));
 if not exists(select 1 from public.characters c where c.id=NEW.character_id and c.is_active) then
  raise exception 'BEST_ANIMATOR_INACTIVE_CHARACTER' using errcode='23514';
 end if;
 if booking.status not in ('cancelled','lead') and exists(
  select 1 from public.order_characters oc join public.orders o on o.id=oc.order_id
  where oc.character_id=NEW.character_id and o.id<>NEW.order_id
   and o.event_date=booking.event_date and o.status not in ('cancelled','lead')
   and o.start_time < booking.start_time + booking.duration_minutes * interval '1 minute'
   and booking.start_time < o.start_time + o.duration_minutes * interval '1 minute'
 ) then raise exception 'BEST_ANIMATOR_CHARACTER_CONFLICT' using errcode='23P01'; end if;
 return NEW;
end $$;
drop trigger if exists order_characters_resource_check on public.order_characters;
create trigger order_characters_resource_check before insert or update on public.order_characters
for each row execute function public.check_character_assignment();

-- Single transaction creates client (if new), booking and assignments. Rollback on any conflict.
create or replace function public.create_booking_v05(
 p_client_id uuid, p_client_name text, p_client_phone text, p_client_source text,
 p_program text, p_event_date date, p_start_time time, p_duration integer,
 p_price bigint, p_location text, p_team_id uuid, p_character_ids uuid[]
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_client uuid; v_order uuid; v_character uuid;
begin
 if (select public.crm_role()) not in ('owner','manager') then raise exception 'BEST_ANIMATOR_FORBIDDEN'; end if;
 if p_event_date is null or p_start_time is null or p_duration not between 15 and 480
   or p_price <= 0 or length(btrim(coalesce(p_location,'')))=0
   or length(btrim(coalesce(p_program,'')))=0 then
  raise exception 'BEST_ANIMATOR_INVALID_BOOKING' using errcode='23514';
 end if;
 if p_team_id is null and coalesce(array_length(p_character_ids,1),0)=0 then
  raise exception 'BEST_ANIMATOR_SELECT_RESOURCES' using errcode='23514';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(p_event_date::text));
 if p_client_id is null then
  insert into public.clients(name,phone,source,created_by)
   values (btrim(p_client_name),btrim(p_client_phone),coalesce(p_client_source,'Instagram'),auth.uid()) returning id into v_client;
 else
  v_client:=p_client_id;
 end if;
 insert into public.orders(client_id,program,event_date,start_time,duration_minutes,price_uzs,status,staff,costume,location,team_id,created_by)
 values(v_client,p_program,p_event_date,p_start_time,p_duration,p_price,'pending','', '',p_location,p_team_id,auth.uid())
 returning id into v_order;
 for v_character in select distinct unnest(coalesce(p_character_ids, array[]::uuid[])) loop
  insert into public.order_characters(order_id,character_id) values(v_order,v_character);
 end loop;
 return v_order;
end $$;
revoke all on function public.create_booking_v05(uuid,text,text,text,text,date,time,integer,bigint,text,uuid,uuid[]) from public,anon;
grant execute on function public.create_booking_v05(uuid,text,text,text,text,date,time,integer,bigint,text,uuid,uuid[]) to authenticated;
commit;

-- IMPORTANT: orders created prior to v0.5 have no structured resource assignments.
-- Assign these manually before relying on the new resource calendar.
select id,event_date,start_time,program,staff,costume from public.orders
where team_id is null and not exists(select 1 from public.order_characters oc where oc.order_id=orders.id)
order by event_date,start_time;
