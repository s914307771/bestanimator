-- BEST Animator CRM v0.7: financial expenses and server-side change journal.
-- Run ONCE after v0.6 on the existing Supabase database.
-- This migration does not delete existing data.
BEGIN;

CREATE TABLE IF NOT EXISTS public.expenses (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
 category text NOT NULL CHECK (category IN ('props','animators','transport','other')),
 amount_uzs bigint NOT NULL CHECK (amount_uzs > 0),
 expense_date date NOT NULL,
 note text NOT NULL DEFAULT '',
 is_voided boolean NOT NULL DEFAULT false,
 void_reason text NOT NULL DEFAULT '',
 created_by uuid REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_by uuid REFERENCES auth.users(id),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT expense_void_reason_required CHECK (NOT is_voided OR length(btrim(void_reason)) > 0)
);
CREATE INDEX IF NOT EXISTS expenses_order_id_idx ON public.expenses(order_id);
CREATE INDEX IF NOT EXISTS expenses_date_idx ON public.expenses(expense_date);

CREATE TABLE IF NOT EXISTS public.financial_audit (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 entity_type text NOT NULL CHECK(entity_type IN ('expense','payment')),
 entity_id uuid NOT NULL,
 action text NOT NULL CHECK(action IN ('INSERT','UPDATE')),
 actor_id uuid REFERENCES auth.users(id),
 occurred_at timestamptz NOT NULL DEFAULT now(),
 before_data jsonb,
 after_data jsonb
);
CREATE INDEX IF NOT EXISTS financial_audit_occurred_idx ON public.financial_audit(occurred_at DESC);
CREATE INDEX IF NOT EXISTS financial_audit_entity_idx ON public.financial_audit(entity_type,entity_id);

CREATE OR REPLACE FUNCTION public.crm_expenses_stamp()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF (SELECT public.crm_role()) NOT IN ('owner','manager') THEN
   RAISE EXCEPTION 'Only owner or manager may change expenses';
 END IF;
 IF TG_OP='INSERT' THEN
   NEW.created_by := auth.uid();
   NEW.created_at := now();
   NEW.updated_by := auth.uid();
   NEW.updated_at := now();
   IF NEW.is_voided THEN RAISE EXCEPTION 'New expenses cannot be voided'; END IF;
 ELSE
   IF OLD.is_voided THEN RAISE EXCEPTION 'Voided expenses are immutable'; END IF;
   NEW.created_by := OLD.created_by;
   NEW.created_at := OLD.created_at;
   NEW.updated_by := auth.uid();
   NEW.updated_at := now();
 END IF;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.crm_financial_audit_write()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.financial_audit(entity_type,entity_id,action,actor_id,before_data,after_data)
 VALUES (CASE WHEN TG_TABLE_NAME='payments' THEN 'payment' ELSE 'expense' END,
   NEW.id,TG_OP,auth.uid(),CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW));
 RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS expenses_stamp_v07 ON public.expenses;
CREATE TRIGGER expenses_stamp_v07 BEFORE INSERT OR UPDATE ON public.expenses
 FOR EACH ROW EXECUTE FUNCTION public.crm_expenses_stamp();
DROP TRIGGER IF EXISTS expenses_audit_v07 ON public.expenses;
CREATE TRIGGER expenses_audit_v07 AFTER INSERT OR UPDATE ON public.expenses
 FOR EACH ROW EXECUTE FUNCTION public.crm_financial_audit_write();
DROP TRIGGER IF EXISTS payments_audit_v07 ON public.payments;
CREATE TRIGGER payments_audit_v07 AFTER INSERT ON public.payments
 FOR EACH ROW EXECUTE FUNCTION public.crm_financial_audit_write();

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.expenses,public.financial_audit FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.expenses TO authenticated;
GRANT SELECT ON public.financial_audit TO authenticated;

DROP POLICY IF EXISTS expenses_read_v07 ON public.expenses;
CREATE POLICY expenses_read_v07 ON public.expenses FOR SELECT TO authenticated
 USING ((SELECT public.crm_role()) IN ('owner','manager'));
DROP POLICY IF EXISTS expenses_insert_v07 ON public.expenses;
CREATE POLICY expenses_insert_v07 ON public.expenses FOR INSERT TO authenticated
 WITH CHECK ((SELECT public.crm_role()) IN ('owner','manager') AND created_by=(SELECT auth.uid()));
DROP POLICY IF EXISTS expenses_update_v07 ON public.expenses;
CREATE POLICY expenses_update_v07 ON public.expenses FOR UPDATE TO authenticated
 USING ((SELECT public.crm_role()) IN ('owner','manager'))
 WITH CHECK ((SELECT public.crm_role()) IN ('owner','manager'));
DROP POLICY IF EXISTS financial_audit_read_v07 ON public.financial_audit;
CREATE POLICY financial_audit_read_v07 ON public.financial_audit FOR SELECT TO authenticated
 USING ((SELECT public.crm_role()) IN ('owner','manager'));

-- To display real staff names (not just short UUIDs), owner and manager may read staff profiles.
DROP POLICY IF EXISTS staff_finance_directory_v07 ON public.staff_profiles;
CREATE POLICY staff_finance_directory_v07 ON public.staff_profiles FOR SELECT TO authenticated
 USING ((SELECT public.crm_role()) IN ('owner','manager'));

-- No UPDATE/DELETE grants for audit log; existing payment ledger also remains append-only.
COMMIT;
