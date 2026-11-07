# BEST Animator CRM — Cloud v0.3

Next.js + Supabase + Vercel. Clients, orders, events and payments synchronize across devices. **Not connected or deployed yet**: user must create Supabase/Vercel projects and set their own credentials.

## Set up Supabase

1. Open https://supabase.com/dashboard → New project.
2. In **SQL Editor**, paste and execute `supabase/schema.sql` (only once on a new empty project).
3. In **Authentication → Users**, create/ invite your owner account by email. If using an invite email, complete password setup before login. Alternatively choose Add user with confirmed password. Never send the password to anyone.
4. In SQL Editor run, replacing the email:

```sql
insert into public.staff_profiles(user_id,display_name,role)
select id,'Владелец','owner' from auth.users where email='YOUR_REAL_EMAIL';
```

5. For manager, create another Auth user and add their `staff_profiles` row with role `manager`. Do not use shared passwords. Disable public signup in Supabase Auth settings once accounts are created.
6. In **Project Settings → API Keys / Data API**, copy your **project URL** and **publishable (or anon) key**. Do NOT use the `service_role` / secret key in `NEXT_PUBLIC_*` variables.

## Deploy online via Vercel

1. Upload project contents to a **private GitHub repository** (do not upload `.env.local`).
2. At https://vercel.com/new import the repository (Framework: Next.js).
3. In Vercel Project → Settings → Environment Variables, set:
   - `NEXT_PUBLIC_SUPABASE_URL` = your Supabase project URL
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = your Supabase publishable / anon key
4. Click Deploy. You will receive `https://<project>.vercel.app`. If adding env vars after initial deployment, redeploy.
5. Open this link on PC and phone; log in using owner/manager credentials. Both devices will see the same records.
6. In Supabase Auth settings set your **Site URL** to the deployed HTTPS origin. Configure email redirect URLs as required for invitation/password reset emails.

## Optional local validation

```bash
cp .env.example .env.local
# fill values
npm install
npm run dev
```

## Workflow

New order → choose existing or create new client → specify event place → save (pending) → Payments tab → record deposit or full payment. The client and location appear in the payments list. Payment records are append-only; refunds are separate transactions.

## Known limitations / prior to production

- Original browser-local orders are **not migrated**. Do not delete browser storage until migrated/backed up.
- No server-side exclusion constraint for overlapping staff/costume bookings yet; client-side detection is not transaction safe.
- An order with a new client is currently two inserts, not an atomic database transaction. If the order insert fails, client may remain.
- Financial ceiling checks and order status transitions are implemented in browser UI, not enforced inside database. Before handling real money, enforce via PostgreSQL RPC/constraints and audit trail.
- Role `animator` exists in schema but has no data access yet; owner/manager can operate CRM.
- Do not import real client information before fully testing roles, policies, backups, and workflows.
- Password reset/invitations are administered via Supabase Auth dashboard until an admin panel is built.
