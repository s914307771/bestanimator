-- Double Bubble Show — v1.2, Stage A: catalog-only additive migration.
-- Assumes the schema shared on 2026-11-07 (characters exists, dbs_services does not).
-- Does NOT alter orders, clients, team assignments, existing triggers or RLS policies.
-- The public booking API must NOT be enabled by this migration alone.

BEGIN;

-- Existing character catalog stays the source of truth for the CRM and Mini App.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS category text NOT NULL DEFAULT 'Аниматоры',
  ADD COLUMN IF NOT EXISTS image_url text,
  ADD COLUMN IF NOT EXISTS is_premium boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS show_in_app boolean NOT NULL DEFAULT false;

-- Default to private for newly created characters; existing rows are unchanged.
ALTER TABLE public.characters
  ALTER COLUMN show_in_app SET DEFAULT false;

-- New marketing/product catalog. No client or payment data here.
CREATE TABLE IF NOT EXISTS public.dbs_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  category text NOT NULL DEFAULT 'Шоу-программы',
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  duration_minutes integer CHECK (duration_minutes BETWEEN 15 AND 480),
  price_mode text NOT NULL DEFAULT 'on_request'
    CHECK (price_mode IN ('fixed', 'from', 'on_request')),
  base_price_uzs bigint CHECK (base_price_uzs >= 0),
  included_characters integer NOT NULL DEFAULT 0 CHECK (included_characters >= 0),
  extra_character_price_uzs bigint CHECK (extra_character_price_uzs >= 0),
  cover_url text,
  is_active boolean NOT NULL DEFAULT false,
  show_in_app boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dbs_services_price_rule CHECK (
    (price_mode = 'on_request') OR (base_price_uzs IS NOT NULL)
  )
);

-- Approved package: visible only after the manager explicitly publishes it.
INSERT INTO public.dbs_services
  (slug, category, title, description, duration_minutes, price_mode,
   base_price_uzs, included_characters, extra_character_price_uzs,
   is_active, show_in_app, sort_order)
VALUES
  ('standard-60', 'Готовые программы', 'Стандартная программа — 60 минут',
   'Два героя; диджей и аппаратура; мыльные пузыри; игры, танцы и конкурсы; фигурки из шариков каждому ребёнку; весь необходимый реквизит; торжественный вынос торта при наличии.',
   60, 'fixed', 1000000, 2, 350000, true, false, 10)
ON CONFLICT (slug) DO NOTHING;

-- Ideas inspired by the reviewed catalogs: no unapproved prices or promises.
INSERT INTO public.dbs_services
  (slug, category, title, description, price_mode, is_active, show_in_app, sort_order)
VALUES
  ('bubble-show', 'Шоу-программы', 'Шоу мыльных пузырей', 'Комплектация и цена уточняются.', 'on_request', false, false, 20),
  ('science-show', 'Шоу-программы', 'Научное шоу', 'Комплектация и цена уточняются.', 'on_request', false, false, 30),
  ('neon-show', 'Шоу-программы', 'Неоновое шоу', 'Комплектация и цена уточняются.', 'on_request', false, false, 40),
  ('laser-show', 'Шоу-программы', 'Лазерное шоу', 'Комплектация и цена уточняются.', 'on_request', false, false, 50),
  ('face-paint', 'Дополнительные услуги', 'Аквагрим', 'Комплектация и цена уточняются.', 'on_request', false, false, 60),
  ('photo-zone', 'Дополнительные услуги', 'Фотозона', 'Комплектация и цена уточняются.', 'on_request', false, false, 70)
ON CONFLICT (slug) DO NOTHING;

-- No direct anonymous/authenticated access: a future validated server API will
-- return only published public fields, never private CRM notes or client data.
ALTER TABLE public.dbs_services ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dbs_services FROM PUBLIC, anon, authenticated;

COMMIT;
