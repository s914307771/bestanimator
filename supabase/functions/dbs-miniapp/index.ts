// Double Bubble Show Mini App API. Supabase Edge Function / Deno.
// VERIFY JWT OFF ONLY because Telegram signed initData is checked below.
// NEVER put SUPABASE_SERVICE_ROLE_KEY or TELEGRAM_BOT_TOKEN in web files.
import { createClient } from "npm:@supabase/supabase-js@2";

type TelegramUser = { id: number; first_name?: string };
const te = new TextEncoder();
const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN") || "";
const supabaseURL = Deno.env.get("SUPABASE_URL") || "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const appOrigin = Deno.env.get("MINIAPP_ORIGIN") || "";
const managerChat = Deno.env.get("DBS_MANAGER_CHAT_ID") || "";
const supabase = supabaseURL && serviceKey ? createClient(supabaseURL, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
}) : null;

function reply(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": appOrigin,
      "Access-Control-Allow-Headers": "content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Vary": "Origin",
      "Cache-Control": "no-store",
    },
  });
}

async function hmac(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, message));
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifiedTelegramUser(rawInitData: unknown): Promise<TelegramUser> {
  if (typeof rawInitData !== "string" || !rawInitData || rawInitData.length > 16384) {
    throw new Error("TELEGRAM_AUTH_REQUIRED");
  }
  const params = new URLSearchParams(rawInitData);
  const seen = new Set<string>();
  for (const [key] of params) {
    if (seen.has(key)) throw new Error("TELEGRAM_AUTH_INVALID");
    seen.add(key);
  }
  const receivedHash = params.get("hash") || "";
  const timestamp = Number(params.get("auth_date"));
  const now = Math.floor(Date.now() / 1000);
  if (!/^[a-f0-9]{64}$/.test(receivedHash) ||
      !Number.isSafeInteger(timestamp) || now - timestamp > 3600 || timestamp - now > 30) {
    throw new Error("TELEGRAM_AUTH_EXPIRED");
  }
  // Signature is a separate Ed25519 field for third-party validation.
  const checkString = [...params.entries()]
    .filter(([key]) => key !== "hash" && key !== "signature")
    .sort(([a], [b]) => a.localeCompare(b, "en"))
    .map(([key, value]) => `${key}=${value}`).join("\n");
  const secret = await hmac(te.encode("WebAppData"), te.encode(botToken));
  const signed = await hmac(secret, te.encode(checkString));
  const calculated = Array.from(signed, b => b.toString(16).padStart(2, "0")).join("");
  if (!constantTimeEqual(calculated, receivedHash)) throw new Error("TELEGRAM_AUTH_INVALID");
  let parsed: unknown;
  try { parsed = JSON.parse(params.get("user") || "null"); }
  catch { throw new Error("TELEGRAM_AUTH_INVALID"); }
  const user = parsed as TelegramUser | null;
  if (!user || !Number.isSafeInteger(user.id) || user.id <= 0) {
    throw new Error("TELEGRAM_USER_REQUIRED");
  }
  return user;
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}
function isDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(value + "T00:00:00Z");
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}
function cleanIds(value: unknown): string[] {
  if (!Array.isArray(value) || value.length < 2 || value.length > 10 ||
      !value.every(isUUID) || new Set(value).size !== value.length) {
    throw new Error("INVALID_CHARACTERS");
  }
  return value;
}
function rejectDatabaseError(message: string) {
  if (/DBS_SLOT_BUSY|BEST_ANIMATOR_CHARACTER_CONFLICT|BEST_ANIMATOR_TEAM_CONFLICT/.test(message))
    return "SLOT_BUSY";
  for (const key of ["DBS_INVALID_CONTACT", "DBS_INVALID_CHARACTERS", "DBS_DAILY_LIMIT", "DBS_PACKAGE_UNAVAILABLE"]) {
    if (message.includes(key)) return key;
  }
  return "BOOKING_FAILED"; // Do not leak DB/RLS internals to the browser.
}

async function notifyManager(orderId: string, info: {
  name: string; phone: string; day: string; time: string; location: string; count: number;
}) {
  if (!managerChat) return false;
  const text = [
    "🎉 Double Bubble Show — новая заявка",
    `Заказ: ${orderId}`,
    `Клиент: ${info.name}`,
    `Телефон: ${info.phone}`,
    `Дата: ${info.day}, ${info.time}`,
    `Героев: ${info.count}`,
    `Адрес: ${info.location}`,
    "Статус: pending. Проверьте исполнителей в CRM.",
  ].join("\n");
  try {
    const ctl = new AbortController();
    const timeout = setTimeout(() => ctl.abort(), 4000);
    try {
      const response = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: managerChat, text }),
        signal: ctl.signal,
      });
      const payload = await response.json();
      return response.ok && payload?.ok === true;
    } finally { clearTimeout(timeout); }
  } catch { return false; }
}

Deno.serve(async (req: Request) => {
  if (!botToken || !supabaseURL || !serviceKey || !appOrigin) {
    return reply(503, { error: "SERVER_NOT_CONFIGURED" });
  }
  const origin = req.headers.get("origin");
  if (origin && origin !== appOrigin) return reply(403, { error: "ORIGIN_NOT_ALLOWED" });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { "Access-Control-Allow-Origin": appOrigin, "Access-Control-Allow-Headers": "content-type", "Access-Control-Allow-Methods": "POST, OPTIONS", "Vary": "Origin" } });
  if (req.method !== "POST") return reply(405, { error: "METHOD_NOT_ALLOWED" });
  if ((Number(req.headers.get("content-length")) || 0) > 32_768)
    return reply(413, { error: "REQUEST_TOO_LARGE" });

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return reply(400, { error: "INVALID_JSON" }); }
  let telegram: TelegramUser;
  try { telegram = await verifiedTelegramUser(body.initData); }
  catch (err) { return reply(401, { error: String((err as Error).message) }); }

  const action = body.action;
  if (action === "catalog") {
    const [characters, services] = await Promise.all([
      supabase!.from("characters")
        .select("id,name,category,image_url,is_premium")
        .eq("is_active", true).eq("show_in_app", true)
        .order("name"),
      supabase!.from("dbs_services")
        .select("slug,title,description,category,duration_minutes,price_mode,base_price_uzs,included_characters,extra_character_price_uzs,cover_url")
        .eq("is_active", true).eq("show_in_app", true)
        .order("sort_order"),
    ]);
    if (characters.error || services.error)
      return reply(503, { error: "CATALOG_UNAVAILABLE" });
    return reply(200, { characters: characters.data || [], services: services.data || [] });
  }
  if (action === "slots") {
    try {
      if (!isDate(body.day)) return reply(400, { error: "INVALID_DAY" });
      const ids = cleanIds(body.character_ids);
      const { data, error } = await supabase!.rpc("dbs_available_slots", {
        p_day: body.day, p_character_ids: ids,
      });
      if (error) return reply(503, { error: "SLOTS_UNAVAILABLE" });
      return reply(200, { slots: (data || []).map((x: { start_time: string }) => x.start_time.slice(0, 5)) });
    } catch { return reply(400, { error: "INVALID_CHARACTERS" }); }
  }
  if (action === "book") {
    if (!isDate(body.day) || !isUUID(body.request_id) ||
        typeof body.time !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(body.time) ||
        typeof body.name !== "string" || typeof body.phone !== "string" ||
        typeof body.location !== "string")
      return reply(400, { error: "INVALID_BOOKING_INPUT" });
    let ids: string[];
    try { ids = cleanIds(body.character_ids); }
    catch { return reply(400, { error: "INVALID_CHARACTERS" }); }
    const { data, error } = await supabase!.rpc("dbs_book_standard_60", {
      p_telegram_user_id: telegram.id.toString(),
      p_request_id: body.request_id,
      p_name: body.name,
      p_phone: body.phone,
      p_day: body.day,
      p_time: body.time,
      p_location: body.location,
      p_character_ids: ids,
    });
    if (error) {
      const reason = rejectDatabaseError(error.message || "");
      return reply(reason === "SLOT_BUSY" ? 409 : 400, { error: reason });
    }
    // Notification is best-effort; CRM order is already committed. A
    // durable outbox/retry worker should replace this before full launch.
    const notified = await notifyManager(String(data), {
      name: body.name, phone: body.phone, day: body.day, time: body.time,
      location: body.location, count: ids.length,
    });
    return reply(200, { order_id: data, status: "pending", manager_notified: notified });
  }
  return reply(400, { error: "UNKNOWN_ACTION" });
});
