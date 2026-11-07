-- READ ONLY. Run after migrations 01 and 02, in a staging project first.
SELECT slug,title,duration_minutes,base_price_uzs,
       extra_character_price_uzs,is_active,show_in_app
FROM public.dbs_services WHERE slug='standard-60';
SELECT COUNT(*) AS characters_total,
       COUNT(*) FILTER (WHERE is_active AND show_in_app AND NOT is_premium) AS published_standard_characters
FROM public.characters;
SELECT status,COUNT(*) AS orders FROM public.orders GROUP BY status ORDER BY status;
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname LIKE 'dbs_%' ORDER BY 1;
SELECT 'orders' AS table_name,count(*) AS row_count FROM public.orders
UNION ALL SELECT 'dbs_miniapp_requests',count(*) FROM public.dbs_miniapp_requests;
-- If >=2 characters are published, use their real IDs in the API to test slots.
