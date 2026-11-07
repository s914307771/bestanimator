-- Double Bubble Show v1.3 preflight (READ-ONLY).
SELECT 'orders_status' AS item, status AS value, count(*) AS total
FROM public.orders GROUP BY status ORDER BY status;

-- Potential blind spots: active CRM orders without characters linked in the
-- junction table are invisible to the Mini App's character availability.
SELECT o.id, o.event_date, o.start_time, o.status, o.costume, o.staff,
       o.team_id
FROM public.orders o
WHERE o.status IN ('pending', 'confirmed', 'done')
AND NOT EXISTS (SELECT 1 FROM public.order_characters oc WHERE oc.order_id=o.id)
ORDER BY o.event_date, o.start_time;

SELECT p.proname AS function_name, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
 AND p.proname IN ('check_resource_order','check_character_assignment');

SELECT tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname='public' AND tablename IN
  ('characters','clients','orders','order_characters','teams')
ORDER BY tablename,policyname;

SELECT table_name,column_name,data_type
FROM information_schema.columns
WHERE table_schema='public'
AND table_name IN ('characters','orders','dbs_services','dbs_miniapp_requests')
ORDER BY table_name,ordinal_position;
