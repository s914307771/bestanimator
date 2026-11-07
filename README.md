# Double Bubble Show — Mini App → existing CRM, v1.3 (2026-11-07)

**Status:** source code / installation candidate, **NOT installed**, **NOT end-to-end tested** against the live Supabase project. The only inputs available were the user's schema, constraints, trigger bodies and previous v1.2 migration. Never deploy publicly without a staging test and review of the real CRM application code.

## What this version connects

| User action | Existing CRM destination | Rule |
|---|---|---|
| List hero photos and names | `public.characters` | `is_active AND show_in_app`; premium display-only |
| List service prices | `public.dbs_services` | Only published, active services |
| Query free hours | `orders` JOIN `order_characters` | Same-date overlaps plus a 30-min travel gap **for Mini App bookings** |
| Submit standard program | `clients` + `orders` + `order_characters` in one transaction | `status='pending'`, no second order table |
| Trace a Telegram submission | `dbs_miniapp_requests` | Maps signed Telegram user and idempotency UUID to CRM order |
| Manager notification | Telegram Bot API, optional | Best effort via `DBS_MANAGER_CHAT_ID`, no reliable retry yet |

**Prices:** standard program 60 min = 1,000,000 UZS, two heroes included, +350,000 UZS each additional. Premium costumes and other shows remain on request and cannot be auto-booked. Staff, DJ, sound equipment and transport have **not** been validated by the slot lookup; the manager must confirm them before promising the program to the customer.

**Status semantics:** `lead` and `cancelled` do not occupy the calendar; `pending`, `confirmed`, and `done` do. Pending stays blocking until staff changes status. **This version does not implement an automatic 15-minute hold or expiry.** This prevents promises the existing triggers cannot honor.

## Contents

- `checks/00_preflight_readonly.sql`: read-only audit of constraints, active orders without characters, RLS policy metadata.
- `supabase/migrations/01_catalog_migration.sql`: exact prior v1.2 Stage A catalog migration. Run **only if not previously applied** and after auditing its effect on a staging copy.
- `supabase/migrations/02_booking_migration.sql`: Stage B new private request table + available-slots and booking RPCs. Does not replace/disable the CRM's existing resource-check triggers. All functions callable by `service_role` only.
- `checks/03_smoke_tests_readonly.sql`: read-only post-deployment inspection.
- `supabase/functions/dbs-miniapp/index.ts`: Deno Edge Function, verifies Telegram signed `initData` before every action, uses service-role access only on the server, offers catalog, slots and transactional booking. Optional manager notification.
- `web/index.html`: standalone mobile frontend, with unavailable-time click to propose nearest available hours. It requires Telegram and a configured HTTPS Edge API endpoint.

## Compatibility/operations requirements — important

1. The CRM's current triggers `orders_resource_check` and `order_characters_resource_check` lock using `pg_advisory_xact_lock(hashtext(event_date::text))`. The new server booking routine deliberately takes **the same lock** and rechecks availability before writing. The older `v1` / `v1.1` migrations used a different lock and **must not** be deployed on top without reconciliation.
2. The existing triggers reject actual overlaps, while the new Mini App imposes an additional 30-minute gap for its reservations. **CRM-created bookings currently do not enforce this 30-minute gap.** This is not a fully unified travel policy until an agreed resource policy is implemented in CRM too.
3. **Critical:** CRM orders added with hero names only in free-text `orders.costume` will not be detected by the Mini App. Every occupied hero must be represented by a row in `order_characters`. Review results of the preflight's missing-link query; adapt CRM's save flow if needed before going public.
4. Bookings do not automatically assign `orders.team_id`; staff and DJ are unvalidated. All Mini App bookings are tentative `pending` until manager review. No customer guarantee of performers before confirmation.
5. Booking uses `SECURITY INVOKER` SQL functions with explicit `service_role` EXECUTE; no `anon` or `authenticated` execution granted. Keep RLS on. Edge functions with `verify_jwt=false` **must check Telegram initData server-side**; it is the sole authentication mechanism used here.
6. No personal information is returned in the public catalog or slots; don't use a client-visible service-role secret. The manager Telegram message includes client details and must be sent only to a private, approved chat.
7. The `DBS_MANAGER_CHAT_ID` notification is optional and best-effort. It may fail or duplicate on a retry. Implement a durable notification outbox, deduplication, and delivery monitoring before relying on it operationally.
8. The UI is Russian-only for now. Add Uzbek translation, equipment/performer calendars, office hours, transport-zone pricing and manager controls before a complete commercial release.

## Safe implementation sequence

**A. First, staging (not the production Supabase).** Export the current schema and basic table data (especially characters, orders, order_characters). On low tiers without managed backups use secure pg_dump or export; protect any client contact details.

**B. Read-only check.** Run `checks/00_preflight_readonly.sql`. Confirm the same functions / statuses as in the conversation. If live CRM has any `pending`, `confirmed` or `done` orders without `order_characters` rows, fix that save path before allowing bookings.

**C. Catalog (only if not already installed).** Run `01_catalog_migration.sql` in staging. It adds character fields, `dbs_services`, and the approved tariff. Existing characters and service items are unpublished by default. If you previously ran v1/v1.1, stop and reconcile the schema manually; don't stack migrations blindly.

**D. Booking backend.** Run `02_booking_migration.sql`. It does not create or alter existing orders but adds private functions and a mapping table. Run `checks/03_smoke_tests_readonly.sql`.

**E. Publish services and heroes in staging via CRM/admin, not publicly:**

```sql
-- EXAMPLE: operator-reviewed publishing step
UPDATE public.dbs_services
SET show_in_app = true
WHERE slug='standard-60' AND is_active=true;
-- In the actual CRM, publish at least two active NON-premium heroes by UUID.
-- UPDATE public.characters SET show_in_app=true WHERE id IN ('<valid-uuid-1>', '<valid-uuid-2>');
```

**F. Deploy the Edge Function.** Create a function named `dbs-miniapp` and paste `supabase/functions/dbs-miniapp/index.ts` or deploy with the Supabase CLI. Set `verify_jwt=false` for this function only; the code performs **independent server-side Telegram initData HMAC and freshness checks**. Required Supabase Edge Function secrets:

- `TELEGRAM_BOT_TOKEN` — BotFather token, server-side only.
- `MINIAPP_ORIGIN` — exact HTTPS origin, e.g. `https://my-dbs-miniapp.vercel.app` (no trailing slash or path).
- `SUPABASE_URL` — Supabase project URL (normally automatically available).
- `SUPABASE_SERVICE_ROLE_KEY` — private legacy service-role key (normally available to Edge Functions); NEVER copy it into frontend or Vercel public env.
- `DBS_MANAGER_CHAT_ID` — OPTIONAL Telegram ID of an approved private manager chat; without it the order still enters CRM, but manager Telegram notification is not sent.

CLI example (in a properly configured Supabase project):

```sh
supabase functions deploy dbs-miniapp --no-verify-jwt
```

**G. Deploy the Mini App site to Vercel as a NEW project** (do not overwrite the current CRM deployment), using the static `web` folder. Replace `__DBS_MINIAPP_API_URL__` in `web/index.html` with the deployed URL such as `https://<project-ref>.supabase.co/functions/v1/dbs-miniapp`. Set `MINIAPP_ORIGIN` to the new Vercel site's exact origin. Configure Telegram bot menu/mini-app URL in BotFather. Do not open using a plain browser for a booking: it requires Telegram signed initData.

**H. End-to-end staging tests (required before production):**

1. Publish two active characters and the standard package. Confirm catalog contains only published items.
2. Book a 60-min slot for two heroes, confirm exactly one new row in `orders`, link rows in `order_characters`, and one `dbs_miniapp_requests` row. Confirm status `pending`, price 1,000,000.
3. Retry the identical `request_id`. Expect the same order UUID and no duplicate order. Manager notification may duplicate — see limitation above.
4. Attempt another booking using a shared hero at an overlapping time and at a start less than 30 minutes after the preceding booking. Expect rejection.
5. Cancel the staging order via CRM (`status='cancelled'`); confirm the time is offered again.
6. Test a CRM-created active booking with correct `order_characters` links. Confirm Mini App excludes overlapping time.
7. Test 3 heroes and verify price 1,350,000 UZS; premium hero should not be selectable for automatic booking.
8. Test simultaneous requests: only one same-character overlapping reservation should commit.
9. Confirm Telegram auth fails for invalid/expired data; verify a service-role token never appears in browser assets or logs.
10. Confirm real CRM calendar UI shows `pending` orders. CRM may currently filter statuses; update frontend to display them if necessary.

## Why this is not yet a public launch

No live database access, CRM source/repository, Vercel admin access, or bot secret was available. The packaged files are not deployed and have not been executed on the user project. The SQL was designed from provided schema and trigger code; compatibility must be tested on a staging copy. Important remaining work: 30-minute travel buffer parity between CRM and Mini App, linked character assignments for CRM-created orders, team/DJ/equipment availability, robust notifications and manager approval workflow.
