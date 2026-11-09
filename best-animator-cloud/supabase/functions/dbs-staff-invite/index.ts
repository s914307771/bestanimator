// Double Bubble Show: owner-only staff invitation, executed inside Supabase.
// Server secrets NEVER leave the Supabase Edge Function runtime.
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

// Keep invitation links on our own CRM, never arbitrary URLs supplied to the API.
const allowedRedirects = new Set([
  "https://best-animator-cloud-git-feature-owner-manager-f7bf33-s914307771.vercel.app",
  "https://best-animator-cloud.vercel.app",
]);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey)
    return json(503, { error: "EDGE_ADMIN_AUTH_NOT_CONFIGURED" });

  const bearer = req.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if (!bearer) return json(401, { error: "UNAUTHORIZED" });

  // Every request is authenticated by Supabase Auth. Caller metadata cannot assign roles.
  const caller = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${bearer}` } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authError } = await caller.auth.getUser(bearer);
  if (authError || !user) return json(401, { error: "UNAUTHORIZED" });

  // RLS allows staff to read their own role; verify the real owner profile.
  const { data: profile, error: profileError } = await caller
    .from("staff_profiles").select("role").eq("user_id", user.id).maybeSingle();
  if (profileError) {
    console.error("STAFF_OWNER_LOOKUP_FAILED", profileError.code);
    return json(503, { error: "STAFF_OWNER_LOOKUP_FAILED" });
  }
  if (profile?.role !== "owner") return json(403, { error: "FORBIDDEN_OWNER_ONLY" });

  let payload: Record<string, unknown>;
  try {
    const raw: unknown = await req.json();
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      return json(400, { error: "INVALID_PAYLOAD" });
    payload = raw as Record<string, unknown>;
  } catch { return json(400, { error: "INVALID_JSON" }); }

  const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
  const name = typeof payload.name === "string" ? payload.name.trim() : "";
  const requestedRedirect = typeof payload.redirectTo === "string"
    ? payload.redirectTo.trim() : "";
  if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email) ||
      email.length > 254 || name.length < 2 || name.length > 80)
    return json(400, { error: "INVALID_EMAIL_OR_NAME" });

  let redirectTo: string;
  try {
    const target = new URL(requestedRedirect);
    if (!allowedRedirects.has(target.origin) ||
        target.username || target.password || target.pathname !== "/" ||
        target.search || target.hash)
      return json(400, { error: "INVALID_CRM_PUBLIC_URL" });
    redirectTo = target.toString();
  } catch { return json(400, { error: "INVALID_CRM_PUBLIC_URL" }); }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  // Admin access is used only for the Auth invitation. Employee data and permission
  // changes below use the owner's JWT and database RLS, with a complete audit trail.
  const { data: invitation, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { display_name: name },
    redirectTo,
  });
  if (inviteError || !invitation.user) {
    console.error("DBS_STAFF_INVITE_FAILED", inviteError?.message);
    return json(400, { error: "AUTH_INVITE_FAILED", detail: inviteError?.message || "Unknown Auth error" });
  }

  const id = invitation.user.id;
  const { data: existing, error: existingError } = await caller.from("staff_profiles")
    .select("role").eq("user_id", id).maybeSingle();
  if (existingError) return json(503, { error: "INVITED_BUT_PROFILE_CHECK_FAILED" });
  if (existing) return json(409, { error: "STAFF_ALREADY_EXISTS" });

  const { error: staffError } = await caller.from("staff_profiles")
    .insert({ user_id: id, display_name: name, role: "manager" });
  if (staffError) {
    console.error("DBS_STAFF_PROFILE_FAILED", staffError.code, staffError.message);
    return json(503, { error: "INVITED_BUT_PROFILE_FAILED", detail: staffError.message });
  }

  const permissions = [
    "orders.create", "orders.update_status", "execution.update",
    "finance.view_payments", "finance.record_payment", "finance.view_expenses",
    "finance.create_expense", "finance.edit_expense", "audit.view",
  ];
  const { error: permissionsError } = await caller.from("staff_permissions").insert(
    permissions.map(permission => ({
      user_id: id, permission, granted_by: user.id,
    }))
  );
  if (permissionsError) {
    console.error("DBS_STAFF_PERMISSIONS_FAILED", permissionsError.code, permissionsError.message);
    return json(503, { error: "INVITED_BUT_PERMISSIONS_FAILED", detail: permissionsError.message });
  }

  return json(200, { ok: true, message: "Приглашение отправлено на email сотрудника" });
});
