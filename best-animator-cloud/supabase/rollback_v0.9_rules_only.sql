-- EMERGENCY ROLLBACK: removes v0.9 access restrictions and validation triggers.
-- DO NOT USE routinely: restores broader v0.8 manager permissions (including refund/void).
-- Does NOT delete new audit/execution/permission tables or existing business records.
BEGIN;
DROP POLICY IF EXISTS orders_insert_v09 ON public.orders;
DROP POLICY IF EXISTS orders_update_v09 ON public.orders;
DROP POLICY IF EXISTS clients_insert_v09 ON public.clients;
DROP POLICY IF EXISTS clients_update_v09 ON public.clients;
DROP POLICY IF EXISTS characters_insert_v09 ON public.characters;
DROP POLICY IF EXISTS characters_update_v09 ON public.characters;
DROP POLICY IF EXISTS teams_insert_v09 ON public.teams;
DROP POLICY IF EXISTS teams_update_v09 ON public.teams;
DROP POLICY IF EXISTS order_characters_insert_v09 ON public.order_characters;
DROP POLICY IF EXISTS recipients_insert_v09 ON public.telegram_recipients;
DROP POLICY IF EXISTS recipients_update_v09 ON public.telegram_recipients;
DROP POLICY IF EXISTS payments_read_v09 ON public.payments;
DROP POLICY IF EXISTS payments_insert_v09 ON public.payments;
DROP POLICY IF EXISTS expenses_read_v09 ON public.expenses;
DROP POLICY IF EXISTS expenses_insert_v09 ON public.expenses;
DROP POLICY IF EXISTS expenses_update_v09 ON public.expenses;
DROP POLICY IF EXISTS audit_read_v09 ON public.financial_audit;
DROP POLICY IF EXISTS dbs_photo_write_restrict_v09 ON storage.objects;
DROP POLICY IF EXISTS dbs_photo_delete_restrict_v09 ON storage.objects;
DROP TRIGGER IF EXISTS payment_validate_v09 ON public.payments;
DROP TRIGGER IF EXISTS sensitive_order_update_v09 ON public.orders;
DROP TRIGGER IF EXISTS sensitive_expense_update_v09 ON public.expenses;
DROP TRIGGER IF EXISTS order_status_log_v09 ON public.orders;
COMMIT;
