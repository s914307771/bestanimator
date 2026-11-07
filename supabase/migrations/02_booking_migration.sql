-- Double Bubble Show v1.3 / Stage B: live CRM booking bridge.
-- Requires Stage A v1.2 catalog and the existing CRM schema/functions exactly as
-- inspected on 2026-11-07. TEST ON STAGING BEFORE PRODUCTION.
-- Does NOT replace existing CRM triggers, does not disable RLS or modify
-- existing rows. Backend-only EXECUTE for all new RPC functions.
BEGIN;

-- Reject mismatched installations before changing anything.
DO $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'dbs_services'
        AND column_name = 'show_in_app'
    ) OR NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'characters'
        AND column_name = 'show_in_app'
    ) THEN
    RAISE EXCEPTION 'DBS_STAGE_A_V1_2_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class r ON r.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=r.relnamespace
    WHERE n.nspname='public' AND r.relname='orders'
      AND t.tgname='orders_resource_check' AND NOT t.tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class r ON r.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=r.relnamespace
    WHERE n.nspname='public' AND r.relname='order_characters'
      AND t.tgname='order_characters_resource_check' AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'DBS_EXPECTED_CRM_TRIGGERS_MISSING';
  END IF;
END $$;

-- Key for idempotent requests, and a private CRM-order to Telegram mapping.
CREATE TABLE IF NOT EXISTS public.dbs_miniapp_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint NOT NULL CHECK (telegram_user_id > 0),
  request_id uuid NOT NULL,
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (telegram_user_id, request_id)
);
ALTER TABLE public.dbs_miniapp_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dbs_miniapp_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON TABLE public.dbs_miniapp_requests TO service_role;

CREATE INDEX IF NOT EXISTS dbs_oc_character_order_idx
 ON public.order_characters(character_id, order_id);
CREATE INDEX IF NOT EXISTS dbs_orders_date_status_start_idx
 ON public.orders(event_date, status, start_time);

-- Private helper: one shared calculation for the Mini App's free-slot display
-- AND its final transaction. Existing CRM checks only hard overlaps; this
-- helper additionally enforces a 30-minute gap between reservations for the
-- SAME CHARACTER. It does not verify DJ, staff, team or equipment availability.
CREATE OR REPLACE FUNCTION public.dbs_character_slot_free(
  p_day date, p_time time without time zone,
  p_character_ids uuid[], p_buffer_minutes integer DEFAULT 30
) RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $function$
  SELECT
    p_day IS NOT NULL AND p_time IS NOT NULL
    AND p_buffer_minutes BETWEEN 0 AND 180
    AND p_time >= time '10:00'
    AND ((extract(epoch from p_time) / 60) + 60) <= 1260
    AND p_day >= (now() AT TIME ZONE 'Asia/Tashkent')::date
    AND p_day <= (now() AT TIME ZONE 'Asia/Tashkent')::date + 365
    AND (p_day + p_time) > (now() AT TIME ZONE 'Asia/Tashkent') + interval '1 hour'
    AND cardinality(p_character_ids) BETWEEN 2 AND 10
    AND (SELECT count(DISTINCT x) FROM unnest(p_character_ids) AS x)
        = cardinality(p_character_ids)
    AND (SELECT count(*) FROM public.characters c
          WHERE c.id = ANY(p_character_ids)
            AND c.is_active AND c.show_in_app AND NOT c.is_premium)
        = cardinality(p_character_ids)
    AND NOT EXISTS (
       SELECT 1
       FROM public.orders o
       JOIN public.order_characters oc ON oc.order_id = o.id
       WHERE o.event_date = p_day
         AND o.status NOT IN ('cancelled', 'lead')
         AND oc.character_id = ANY(p_character_ids)
         AND o.start_time < (p_time + make_interval(mins => 60 + p_buffer_minutes))
         AND p_time < (o.start_time + make_interval(mins => o.duration_minutes + p_buffer_minutes))
    );
$function$;

-- 30-minute increments from 10:00 to 20:00. No fake availability is emitted:
-- every row is based on current public.orders / public.order_characters.
-- A slot is an estimate until committed; the booking function rechecks.
CREATE OR REPLACE FUNCTION public.dbs_available_slots(
  p_day date, p_character_ids uuid[]
) RETURNS TABLE(start_time time without time zone)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $function$
 SELECT gs.slot::time AS start_time
 FROM generate_series(p_day + time '10:00', p_day + time '20:00', interval '30 minutes') AS gs(slot)
 WHERE EXISTS (
   SELECT 1 FROM public.dbs_services s
   WHERE s.slug = 'standard-60' AND s.is_active AND s.show_in_app
     AND s.price_mode = 'fixed' AND s.duration_minutes = 60
     AND s.included_characters = 2 AND s.extra_character_price_uzs IS NOT NULL
 )
 AND public.dbs_character_slot_free(p_day, gs.slot::time, p_character_ids, 30)
 ORDER BY 1;
$function$;

-- Transactional write to the ACTUAL CRM tables. Security INVOKER means this
-- can run only under the server's service_role, never with anon/client keys.
-- It takes exactly the same date-level advisory lock as existing CRM triggers.
-- The two character INSERTS (and all other mutations) roll back together if
-- ANY existing CRM trigger rejects a conflict.
CREATE OR REPLACE FUNCTION public.dbs_book_standard_60(
  p_telegram_user_id bigint,
  p_request_id uuid,
  p_name text,
  p_phone text,
  p_day date,
  p_time time without time zone,
  p_location text,
  p_character_ids uuid[]
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = ''
AS $function$
DECLARE
  v_service public.dbs_services%rowtype;
  v_existing uuid;
  v_client uuid;
  v_order uuid;
  v_count integer;
BEGIN
  IF p_telegram_user_id IS NULL OR p_telegram_user_id <= 0 OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'DBS_INVALID_TELEGRAM_CONTEXT' USING errcode = '22023';
  END IF;
  IF char_length(btrim(coalesce(p_name,''))) NOT BETWEEN 2 AND 120
     OR char_length(btrim(coalesce(p_phone,''))) NOT BETWEEN 7 AND 30
     OR p_phone !~ '^[+0-9 ()-]+$'
     OR char_length(btrim(coalesce(p_location,''))) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'DBS_INVALID_CONTACT' USING errcode = '22023';
  END IF;

  -- Lock identical submissions across retries (even with different day args).
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('dbs_request_' || p_telegram_user_id::text || '_' || p_request_id::text));
  SELECT r.order_id INTO v_existing
  FROM public.dbs_miniapp_requests r
  WHERE r.telegram_user_id = p_telegram_user_id AND r.request_id = p_request_id;
  IF FOUND THEN RETURN v_existing; END IF;

  IF (SELECT count(*) FROM public.dbs_miniapp_requests r
       WHERE r.telegram_user_id = p_telegram_user_id
         AND r.created_at > now() - interval '1 day') >= 5 THEN
    RAISE EXCEPTION 'DBS_DAILY_LIMIT' USING errcode = '22023';
  END IF;

  SELECT * INTO v_service FROM public.dbs_services s
  WHERE s.slug = 'standard-60' AND s.is_active AND s.show_in_app
    AND s.price_mode = 'fixed' AND s.duration_minutes = 60
    AND s.included_characters = 2 AND s.base_price_uzs IS NOT NULL
    AND s.extra_character_price_uzs IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DBS_PACKAGE_UNAVAILABLE' USING errcode = '22023';
  END IF;

  v_count := cardinality(p_character_ids);
  IF v_count IS NULL OR v_count < 2 OR v_count > 10 THEN
    RAISE EXCEPTION 'DBS_INVALID_CHARACTERS' USING errcode = '22023';
  END IF;

  -- This matches pg_advisory_xact_lock(hashtext(NEW.event_date::text))
  -- inside check_resource_order() and check_character_assignment().
  IF p_day IS NULL THEN RAISE EXCEPTION 'DBS_INVALID_DAY' USING errcode = '22023'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(p_day::text));

  IF NOT public.dbs_character_slot_free(p_day,p_time,p_character_ids,30) THEN
    RAISE EXCEPTION 'DBS_SLOT_BUSY' USING errcode = '23P01';
  END IF;

  -- Avoid duplicate contacts from simultaneous Mini App bookings on diff days.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dbs_client_' || btrim(p_phone)));
  SELECT c.id INTO v_client FROM public.clients c
  WHERE c.phone = btrim(p_phone) ORDER BY c.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO public.clients(name,phone,source)
    VALUES (btrim(p_name), btrim(p_phone), 'Telegram Mini App')
    RETURNING id INTO v_client;
  END IF;

  INSERT INTO public.orders
    (client_id, program, event_date, start_time, duration_minutes,
     price_uzs, status, location)
  VALUES
    (v_client, v_service.title, p_day,p_time,60,
     v_service.base_price_uzs + (v_count - 2) * v_service.extra_character_price_uzs,
     'pending', btrim(p_location))
  RETURNING id INTO v_order;

  INSERT INTO public.order_characters(order_id,character_id)
    SELECT v_order, x FROM unnest(p_character_ids) AS x;

  INSERT INTO public.dbs_miniapp_requests(telegram_user_id,request_id,order_id)
    VALUES(p_telegram_user_id,p_request_id,v_order);
  RETURN v_order;
END;
$function$;

REVOKE ALL ON FUNCTION public.dbs_character_slot_free(date,time without time zone,uuid[],integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dbs_available_slots(date,uuid[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.dbs_book_standard_60(bigint,uuid,text,text,date,time without time zone,text,uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dbs_character_slot_free(date,time without time zone,uuid[],integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.dbs_available_slots(date,uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.dbs_book_standard_60(bigint,uuid,text,text,date,time without time zone,text,uuid[]) TO service_role;

COMMIT;
