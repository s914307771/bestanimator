-- BEST Animator Cloud v0.4: SERVER-SIDE conflict protection
-- Run in Supabase SQL Editor after v0.3 schema is installed.
-- Policy for now: one active event at a time for the whole company.
-- Overlapping bookings for different teams will be enabled in a future resource planner.
-- Existing overlapping orders are NOT deleted and remain visible; resolve them manually.

create or replace function public.reject_overlapping_orders()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Reject events that extend beyond the selected calendar day.
  if (extract(epoch from NEW.start_time) / 60 + NEW.duration_minutes) > 1440 then
    raise exception 'BEST_ANIMATOR_EVENT_CROSSES_MIDNIGHT' using errcode = '23514';
  end if;

  if NEW.status in ('cancelled', 'lead') then
    return NEW;
  end if;

  -- Serialize checks for the same date: prevents concurrent staff bookings.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(NEW.event_date::text));

  if exists (
    select 1 from public.orders o
    where o.event_date = NEW.event_date
      and o.id is distinct from NEW.id
      and o.status not in ('cancelled', 'lead')
      and extract(epoch from o.start_time) < extract(epoch from NEW.start_time) + NEW.duration_minutes * 60
      and extract(epoch from NEW.start_time) < extract(epoch from o.start_time) + o.duration_minutes * 60
  ) then
    raise exception 'BEST_ANIMATOR_TIME_CONFLICT' using errcode = '23P01';
  end if;
  return NEW;
end;
$$;

drop trigger if exists orders_no_overlap on public.orders;
create trigger orders_no_overlap
before insert or update of event_date, start_time, duration_minutes, status
on public.orders
for each row execute function public.reject_overlapping_orders();

-- Optional audit query: existing conflicts that must be resolved manually.
select a.id as order_1, b.id as order_2,
       a.event_date, a.start_time as start_1, b.start_time as start_2
from public.orders a
join public.orders b on a.id < b.id and a.event_date = b.event_date
where a.status not in ('cancelled','lead')
  and b.status not in ('cancelled','lead')
  and extract(epoch from a.start_time) < extract(epoch from b.start_time) + b.duration_minutes * 60
  and extract(epoch from b.start_time) < extract(epoch from a.start_time) + a.duration_minutes * 60;
