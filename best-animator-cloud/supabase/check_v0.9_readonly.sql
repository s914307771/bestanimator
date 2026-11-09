-- READ ONLY: Check objects after migration v0.9.
SELECT name, present FROM (
 SELECT 'staff_permissions' AS name, to_regclass('public.staff_permissions') IS NOT NULL AS present
 UNION ALL SELECT 'permission_audit', to_regclass('public.permission_audit') IS NOT NULL
 UNION ALL SELECT 'order_execution', to_regclass('public.order_execution') IS NOT NULL
 UNION ALL SELECT 'order_execution_audit', to_regclass('public.order_execution_audit') IS NOT NULL
 UNION ALL SELECT 'order_status_audit', to_regclass('public.order_status_audit') IS NOT NULL
) q;
SELECT p.display_name,p.role,COALESCE(string_agg(sp.permission,', ' ORDER BY sp.permission),'—') AS granted
FROM public.staff_profiles p LEFT JOIN public.staff_permissions sp ON sp.user_id=p.user_id
GROUP BY p.user_id,p.display_name,p.role ORDER BY p.role,p.display_name;
SELECT event_object_table,trigger_name FROM information_schema.triggers
WHERE trigger_schema='public'
  AND trigger_name IN ('payment_validate_v09','sensitive_order_update_v09','sensitive_expense_update_v09',
  'order_status_log_v09','execution_stamp_v09','execution_audit_v09','staff_permissions_log_v09')
ORDER BY event_object_table,trigger_name;
