# BEST Animator Cloud v0.6

## What's new
- Click a booking in general calendar or its client in Orders/Dashboard to see a detailed modal.
- Detail shows client name, click-to-call phone, event place/date/time, team, characters, status, price, paid, due and payment history.
- Receive payment **after** saving order using 'Перейти к оплате'.
- Telegram recipient registry: manager receives reminders for ALL active orders, animator receives only orders of selected team.
- Vercel Cron at **03:00 UTC = 08:00 Asia/Tashkent** once daily.

## Install safely (important order)
1. Back up Supabase. Ensure `migration_v0.5_resources.sql` was run and v0.5 works.
2. Execute **only** `supabase/migration_v0.6_telegram.sql` in Supabase SQL Editor. Don't re-execute previous migrations.
3. Upload updated app files, lib, package.json and NEW `vercel.json` to the SAME GitHub folder that Vercel uses as Root Directory. Do not put vercel.json in the repository root if Vercel Root Directory is `best-animator-cloud`.
4. In Vercel Project → Settings → Environment Variables, set **Production**:
   - `NEXT_PUBLIC_SUPABASE_URL`: existing public Supabase project URL.
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`: existing public anon key.
   - `SUPABASE_SERVICE_ROLE_KEY`: Supabase service_role key **SECRET, server only; NEVER NEXT_PUBLIC**, never post it in chat or GitHub.
   - `TELEGRAM_BOT_TOKEN`: token from BotFather (**secret**).
   - `CRON_SECRET`: unique long random server secret (e.g. generated securely using password manager). Vercel Cron sends it automatically as `Authorization: Bearer ...`.
5. Redeploy Vercel. Never put `.env.local` in GitHub.
6. Create a Telegram bot with @BotFather. Each recipient must open the bot and send `/start`. Obtain numeric `chat_id` from Telegram Bot API `getUpdates` securely **outside GitHub / screenshots**, or using a trusted chat-ID bot; check carefully before registration.
7. Open CRM → Telegram → add manager and animators, selecting a TEAM for each animator.
8. Validate event modal in Orders and general Calendar. Check a test notification with one test booking on the next scheduled 08:00 run. View Vercel Cron logs. Avoid using a production bot or real customers until validated.

## Security and behavior
- Vercel cron invokes the server-only route, checking the secret token.
- Browser never accesses Telegram token or Supabase service role key.
- Server-only `telegram_delivery_log` prevents duplicate daily sends per order and recipient. If Telegram returns an error, the claim is removed to permit retry.
- Only `pending` and `confirmed` orders get today's reminders. Cancelled, lead and done excluded.
- Reminder is at 08:00 daily **not** per-event or live. For multiple same-day events, managers receive separate notifications. If you add bookings after 08:00, they will not receive an automatic reminder that day in this release.
- Individual employees are not yet assigned to teams: all Telegram recipients linked to a team receive that team's reminders. More granular employee-level allocation is a later feature.
- The existing v0.5 booking rules are unchanged.

## Test checklist
- Click an event in Calendar -> detail opens.
- Click a client in Orders -> detail opens.
- Change status in detail, refresh, ensure it persists.
- Phone link dials, payment button opens separate payment form with order selected.
- Add one manager/animator recipient with valid chat IDs, check daily send once.
- Security: check no secret keys have a `NEXT_PUBLIC_` prefix.

## Caveat
The package has not been fully built in this environment if dependency installation is unavailable. Test new deployment in Vercel and review runtime logs. Deployment not performed on your accounts.
