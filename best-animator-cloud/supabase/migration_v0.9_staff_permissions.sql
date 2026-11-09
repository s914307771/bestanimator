-- Double Bubble Show CRM v0.9 - per-user permissions and execution tracking.
-- PRECONDITION: schema.sql + migrations v0.4..v0.8 applied.
-- Apply ONCE in Supabase SQL Editor; do not run until code is staged in Preview.
-- No existing orders, clients, payments, expenses or character rows are deleted.
BEGIN;

CREATE TABLE IF NOT EXISTS public.staff_permissions (
  user_id uuid NOT NULL REFERENCES public.staff_profiles(user_id) ON DELETE CASCADE,
  permission text NOT NULL CHECK (permission IN (
    'orders.create','orders.update_status','orders.cancel','orders.complete',
    'execution.update','catalog.manage','teams.manage','telegram.manage',
    'finance.view_payments','finance.record_payment','finance.record_refund',
    'finance.view_expenses','finance.create_expense','finance.edit_expense',
    'finance.void_expense','audit.view')),
  granted_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id,permission)
);
CREATE INDEX IF NOT EXISTS staff_permissions_permission_idx ON public.staff_permissions(permission);

CREATE OR REPLACE FUNCTION public.crm_can(p_permission text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT COALESCE((SELECT public.crm_role()) = 'owner',false) OR
   (COALESCE((SELECT public.crm_role()) = 'manager',false) AND EXISTS (
    SELECT 1 FROM public.staff_permissions sp
    WHERE sp.user_id = (SELECT auth.uid()) AND sp.permission = p_permission));
$$;
REVOKE ALL ON FUNCTION public.crm_can(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.crm_can(text) TO authenticated;

ALTER TABLE public.staff_permissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_permissions FROM anon,authenticated;
GRANT SELECT,INSERT,DELETE ON public.staff_permissions TO authenticated;
DROP POLICY IF EXISTS staff_permissions_read_v09 ON public.staff_permissions;
CREATE POLICY staff_permissions_read_v09 ON public.staff_permissions FOR SELECT TO authenticated
 USING (user_id=(SELECT auth.uid()) OR (SELECT public.crm_role())='owner');
DROP POLICY IF EXISTS staff_permissions_insert_v09 ON public.staff_permissions;
CREATE POLICY staff_permissions_insert_v09 ON public.staff_permissions FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_role())='owner' AND granted_by=(SELECT auth.uid())
   AND EXISTS (SELECT 1 FROM public.staff_profiles p WHERE p.user_id=staff_permissions.user_id AND p.role='manager'));
DROP POLICY IF EXISTS staff_permissions_delete_v09 ON public.staff_permissions;
CREATE POLICY staff_permissions_delete_v09 ON public.staff_permissions FOR DELETE TO authenticated
 USING ((SELECT public.crm_role())='owner');

-- An owner can register the profile of a previously invited Auth user, without altering any Auth secrets.
GRANT INSERT ON public.staff_profiles TO authenticated;
DROP POLICY IF EXISTS staff_profiles_insert_v09 ON public.staff_profiles;
CREATE POLICY staff_profiles_insert_v09 ON public.staff_profiles FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_role())='owner' AND role IN ('manager','animator'));

-- Audit every permission change, including owner-provided authorizations.
CREATE TABLE IF NOT EXISTS public.permission_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id uuid NOT NULL,
 permission text NOT NULL,
 action text NOT NULL CHECK (action IN ('GRANT','REVOKE')),
 actor_id uuid,
 occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.dbsa_permission_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.permission_audit(user_id,permission,action,actor_id)
 VALUES (CASE WHEN TG_OP='INSERT' THEN NEW.user_id ELSE OLD.user_id END,
         CASE WHEN TG_OP='INSERT' THEN NEW.permission ELSE OLD.permission END,
         CASE WHEN TG_OP='INSERT' THEN 'GRANT' ELSE 'REVOKE' END,
         auth.uid());
 RETURN CASE WHEN TG_OP='INSERT' THEN NEW ELSE OLD END;
END $$;
DROP TRIGGER IF EXISTS staff_permissions_log_v09 ON public.staff_permissions;
CREATE TRIGGER staff_permissions_log_v09 AFTER INSERT OR DELETE ON public.staff_permissions
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_permission_log();
ALTER TABLE public.permission_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.permission_audit FROM anon,authenticated;
GRANT SELECT ON public.permission_audit TO authenticated;
DROP POLICY IF EXISTS permission_audit_owner_v09 ON public.permission_audit;
CREATE POLICY permission_audit_owner_v09 ON public.permission_audit FOR SELECT TO authenticated
 USING ((SELECT public.crm_role())='owner');

-- The existing managers receive scoped operational permissions, not refunds, cancellations,
-- expense voiding, staff management or final completion approval.
INSERT INTO public.staff_permissions(user_id,permission,granted_by)
SELECT p.user_id, v.permission, NULL::uuid
FROM public.staff_profiles p
CROSS JOIN (VALUES
 ('orders.create'),('orders.update_status'),('execution.update'),('catalog.manage'),
 ('teams.manage'),('telegram.manage'),('finance.view_payments'),('finance.record_payment'),('finance.view_expenses'),
 ('finance.create_expense'),('finance.edit_expense'),('audit.view')
) v(permission)
WHERE p.role='manager'
ON CONFLICT DO NOTHING;

-- RLS: existing policies only check owner/manager; RESTRICTIVE policies enforce individual permissions.
DROP POLICY IF EXISTS orders_insert_v09 ON public.orders;
CREATE POLICY orders_insert_v09 AS RESTRICTIVE ON public.orders FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('orders.create')));
DROP POLICY IF EXISTS orders_update_v09 ON public.orders;
CREATE POLICY orders_update_v09 AS RESTRICTIVE ON public.orders FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('orders.update_status')))
 WITH CHECK ((SELECT public.crm_can('orders.update_status')));
DROP POLICY IF EXISTS clients_insert_v09 ON public.clients;
CREATE POLICY clients_insert_v09 AS RESTRICTIVE ON public.clients FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('orders.create')));
DROP POLICY IF EXISTS clients_update_v09 ON public.clients;
CREATE POLICY clients_update_v09 AS RESTRICTIVE ON public.clients FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('orders.create')))
 WITH CHECK ((SELECT public.crm_can('orders.create')));
DROP POLICY IF EXISTS characters_insert_v09 ON public.characters;
CREATE POLICY characters_insert_v09 AS RESTRICTIVE ON public.characters FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('catalog.manage')));
DROP POLICY IF EXISTS characters_update_v09 ON public.characters;
CREATE POLICY characters_update_v09 AS RESTRICTIVE ON public.characters FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('catalog.manage')))
 WITH CHECK ((SELECT public.crm_can('catalog.manage')));
DROP POLICY IF EXISTS teams_insert_v09 ON public.teams;
CREATE POLICY teams_insert_v09 AS RESTRICTIVE ON public.teams FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('teams.manage')));
DROP POLICY IF EXISTS teams_update_v09 ON public.teams;
CREATE POLICY teams_update_v09 AS RESTRICTIVE ON public.teams FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('teams.manage')))
 WITH CHECK ((SELECT public.crm_can('teams.manage')));
DROP POLICY IF EXISTS order_characters_insert_v09 ON public.order_characters;
CREATE POLICY order_characters_insert_v09 AS RESTRICTIVE ON public.order_characters FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('orders.create')));
DROP POLICY IF EXISTS recipients_insert_v09 ON public.telegram_recipients;
CREATE POLICY recipients_insert_v09 AS RESTRICTIVE ON public.telegram_recipients FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('telegram.manage')));
DROP POLICY IF EXISTS recipients_update_v09 ON public.telegram_recipients;
CREATE POLICY recipients_update_v09 AS RESTRICTIVE ON public.telegram_recipients FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('telegram.manage')))
 WITH CHECK ((SELECT public.crm_can('telegram.manage')));
DROP POLICY IF EXISTS payments_read_v09 ON public.payments;
CREATE POLICY payments_read_v09 AS RESTRICTIVE ON public.payments FOR SELECT TO authenticated
 USING ((SELECT public.crm_can('finance.view_payments')));
DROP POLICY IF EXISTS payments_insert_v09 ON public.payments;
CREATE POLICY payments_insert_v09 AS RESTRICTIVE ON public.payments FOR INSERT TO authenticated
 WITH CHECK ((kind='payment' AND (SELECT public.crm_can('finance.record_payment')))
   OR (kind='refund' AND (SELECT public.crm_can('finance.record_refund'))));
DROP POLICY IF EXISTS expenses_read_v09 ON public.expenses;
CREATE POLICY expenses_read_v09 AS RESTRICTIVE ON public.expenses FOR SELECT TO authenticated
 USING ((SELECT public.crm_can('finance.view_expenses')));
DROP POLICY IF EXISTS expenses_insert_v09 ON public.expenses;
CREATE POLICY expenses_insert_v09 AS RESTRICTIVE ON public.expenses FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('finance.create_expense')));
DROP POLICY IF EXISTS expenses_update_v09 ON public.expenses;
CREATE POLICY expenses_update_v09 AS RESTRICTIVE ON public.expenses FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('finance.edit_expense')) OR (SELECT public.crm_can('finance.void_expense')))
 WITH CHECK ((SELECT public.crm_can('finance.edit_expense')) OR (SELECT public.crm_can('finance.void_expense')));
DROP POLICY IF EXISTS audit_read_v09 ON public.financial_audit;
CREATE POLICY audit_read_v09 AS RESTRICTIVE ON public.financial_audit FOR SELECT TO authenticated
 USING ((SELECT public.crm_can('audit.view')));

-- Server-side ledger consistency and attribution. Serialization on the order row prevents concurrent overpayment.
CREATE OR REPLACE FUNCTION public.dbsa_validate_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_price bigint; v_status text; v_net bigint;
BEGIN
 SELECT price_uzs,status INTO v_price,v_status FROM public.orders WHERE id=NEW.order_id FOR UPDATE;
 IF v_price IS NULL OR v_status='cancelled' THEN
   RAISE EXCEPTION 'PAYMENT_FOR_CANCELLED_OR_MISSING_ORDER' USING ERRCODE='23514';
 END IF;
 SELECT COALESCE(SUM(CASE WHEN kind='payment' THEN amount_uzs ELSE -amount_uzs END),0)
   INTO v_net FROM public.payments WHERE order_id=NEW.order_id;
 IF NEW.kind='payment' AND v_net+NEW.amount_uzs>v_price THEN
   RAISE EXCEPTION 'PAYMENT_EXCEEDS_ORDER_PRICE' USING ERRCODE='23514';
 END IF;
 IF NEW.kind='refund' AND NEW.amount_uzs>v_net THEN
   RAISE EXCEPTION 'REFUND_EXCEEDS_RECEIVED_FUNDS' USING ERRCODE='23514';
 END IF;
 NEW.created_by:=auth.uid();
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS payment_validate_v09 ON public.payments;
CREATE TRIGGER payment_validate_v09 BEFORE INSERT ON public.payments
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_validate_payment();

-- Separate permission for cancellations, final completion and voiding expenses;
-- RLS by itself cannot reliably compare OLD vs NEW values.
CREATE OR REPLACE FUNCTION public.dbsa_sensitive_order_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF (SELECT public.crm_role())='manager' AND
    (to_jsonb(NEW)-'status') IS DISTINCT FROM (to_jsonb(OLD)-'status') THEN
   RAISE EXCEPTION 'MANAGER_CAN_CHANGE_ONLY_ORDER_STATUS' USING ERRCODE='42501';
 END IF;
 IF NEW.status='cancelled' AND OLD.status IS DISTINCT FROM NEW.status
     AND NOT (SELECT public.crm_can('orders.cancel')) THEN
   RAISE EXCEPTION 'OWNER_APPROVAL_REQUIRED_CANCEL_ORDER' USING ERRCODE='42501';
 END IF;
 IF NEW.status='done' AND OLD.status IS DISTINCT FROM NEW.status
     AND NOT (SELECT public.crm_can('orders.complete')) THEN
   RAISE EXCEPTION 'OWNER_APPROVAL_REQUIRED_COMPLETE_ORDER' USING ERRCODE='42501';
 END IF;
 IF NEW.price_uzs IS DISTINCT FROM OLD.price_uzs
     AND (SELECT public.crm_role()) <> 'owner' THEN
   RAISE EXCEPTION 'OWNER_ONLY_CHANGE_PRICE' USING ERRCODE='42501';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensitive_order_update_v09 ON public.orders;
CREATE TRIGGER sensitive_order_update_v09 BEFORE UPDATE ON public.orders
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_sensitive_order_update();

CREATE OR REPLACE FUNCTION public.dbsa_sensitive_expense_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF NEW.is_voided IS DISTINCT FROM OLD.is_voided THEN
  IF (to_jsonb(NEW)-'is_voided'-'void_reason'-'updated_by'-'updated_at')
    IS DISTINCT FROM (to_jsonb(OLD)-'is_voided'-'void_reason'-'updated_by'-'updated_at') THEN
    RAISE EXCEPTION 'EXPENSE_VOID_CANNOT_MODIFY_AMOUNT' USING ERRCODE='42501';
  END IF;
  IF NOT (SELECT public.crm_can('finance.void_expense')) THEN
    RAISE EXCEPTION 'OWNER_APPROVAL_REQUIRED_VOID_EXPENSE' USING ERRCODE='42501';
  END IF;
 ELSE
  IF NOT (SELECT public.crm_can('finance.edit_expense')) THEN
    RAISE EXCEPTION 'EXPENSE_EDIT_FORBIDDEN' USING ERRCODE='42501';
  END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensitive_expense_update_v09 ON public.expenses;
CREATE TRIGGER sensitive_expense_update_v09 BEFORE UPDATE ON public.expenses
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_sensitive_expense_update();

-- Every booking status change is separately audited, including the actor who changed it.
CREATE TABLE IF NOT EXISTS public.order_status_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
 previous_status text NOT NULL,
 new_status text NOT NULL,
 actor_id uuid REFERENCES auth.users(id),
 occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.dbsa_order_status_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF OLD.status IS DISTINCT FROM NEW.status THEN
  INSERT INTO public.order_status_audit(order_id,previous_status,new_status,actor_id)
  VALUES(NEW.id,OLD.status,NEW.status,auth.uid());
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS order_status_log_v09 ON public.orders;
CREATE TRIGGER order_status_log_v09 AFTER UPDATE OF status ON public.orders
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_order_status_log();
ALTER TABLE public.order_status_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_status_audit FROM anon,authenticated;
GRANT SELECT ON public.order_status_audit TO authenticated;
DROP POLICY IF EXISTS order_status_owner_read_v09 ON public.order_status_audit;
CREATE POLICY order_status_owner_read_v09 ON public.order_status_audit FOR SELECT TO authenticated
 USING ((SELECT public.crm_role())='owner');

-- Execution milestones are independent of the booking's financial status.
CREATE TABLE IF NOT EXISTS public.order_execution (
 order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE RESTRICT,
 stage text NOT NULL DEFAULT 'new' CHECK(stage IN
 ('new','contacted','confirmed','preparing','ready','on_site','performed','issue')),
 note text NOT NULL DEFAULT '' CHECK(length(note)<=2000),
 updated_by uuid REFERENCES auth.users(id),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.order_execution_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
 old_stage text, new_stage text NOT NULL,
 old_note text, new_note text NOT NULL,
 actor_id uuid REFERENCES auth.users(id),
 occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.dbsa_execution_stamp()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF NOT (SELECT public.crm_can('execution.update')) THEN
   RAISE EXCEPTION 'EXECUTION_UPDATE_FORBIDDEN' USING ERRCODE='42501';
 END IF;
 NEW.updated_by:=auth.uid();
 NEW.updated_at:=now();
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.dbsa_execution_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.order_execution_audit(order_id,old_stage,new_stage,old_note,new_note,actor_id)
 VALUES (NEW.order_id,CASE WHEN TG_OP='UPDATE' THEN OLD.stage ELSE NULL END,NEW.stage,
  CASE WHEN TG_OP='UPDATE' THEN OLD.note ELSE NULL END,NEW.note,auth.uid());
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS execution_stamp_v09 ON public.order_execution;
CREATE TRIGGER execution_stamp_v09 BEFORE INSERT OR UPDATE ON public.order_execution
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_execution_stamp();
DROP TRIGGER IF EXISTS execution_audit_v09 ON public.order_execution;
CREATE TRIGGER execution_audit_v09 AFTER INSERT OR UPDATE ON public.order_execution
 FOR EACH ROW EXECUTE FUNCTION public.dbsa_execution_audit();
ALTER TABLE public.order_execution ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_execution_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_execution,public.order_execution_audit FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.order_execution TO authenticated;
GRANT SELECT ON public.order_execution_audit TO authenticated;
DROP POLICY IF EXISTS execution_read_v09 ON public.order_execution;
CREATE POLICY execution_read_v09 ON public.order_execution FOR SELECT TO authenticated
 USING ((SELECT public.crm_role()) IN ('owner','manager'));
DROP POLICY IF EXISTS execution_insert_v09 ON public.order_execution;
CREATE POLICY execution_insert_v09 ON public.order_execution FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_can('execution.update')));
DROP POLICY IF EXISTS execution_update_v09 ON public.order_execution;
CREATE POLICY execution_update_v09 ON public.order_execution FOR UPDATE TO authenticated
 USING ((SELECT public.crm_can('execution.update')))
 WITH CHECK ((SELECT public.crm_can('execution.update')));
DROP POLICY IF EXISTS execution_audit_read_v09 ON public.order_execution_audit;
CREATE POLICY execution_audit_read_v09 ON public.order_execution_audit FOR SELECT TO authenticated
 USING ((SELECT public.crm_role())='owner' OR (SELECT public.crm_can('execution.update')));

-- Restrict Storage write access for character cards when the owner's catalog permission is revoked.
DROP POLICY IF EXISTS dbs_photo_write_restrict_v09 ON storage.objects;
CREATE POLICY dbs_photo_write_restrict_v09 AS RESTRICTIVE ON storage.objects FOR INSERT TO authenticated
 WITH CHECK (bucket_id <> 'dbs-character-cards' OR (SELECT public.crm_can('catalog.manage')));
DROP POLICY IF EXISTS dbs_photo_delete_restrict_v09 ON storage.objects;
CREATE POLICY dbs_photo_delete_restrict_v09 AS RESTRICTIVE ON storage.objects FOR DELETE TO authenticated
 USING (bucket_id <> 'dbs-character-cards' OR (SELECT public.crm_can('catalog.manage')));

COMMIT;
