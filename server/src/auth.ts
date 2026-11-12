// The one secret, SOZVON_PASSWORD: the app sends it as a bearer token, the sign-in page asks for it.
// Compared in constant time; wrong attempts are slowed down and, per IP (per /64 for IPv6), locked out for a while.
import { ensureSchema } from "./db";

export const FAIL_DELAY_MS = 1000;
export const MAX_FAILURES = 10;
export const WINDOW_MS = 15 * 60 * 1000;

const sha256 = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

/** Constant-time comparison: both sides are hashed first, so length leaks nothing either. */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/** A short tag of the password stored in OAuth grants: changing the password signs every connector out. */
export async function passwordTag(password: string): Promise<string> {
  const h = await sha256(`sozvon-grant:${password}`);
  return Array.from(h.slice(0, 12), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function bearer(request: Request): string {
  const m = /^Bearer\s+(.+)$/i.exec(request.headers.get("Authorization") ?? "");
  return m ? m[1].trim() : "";
}

/** The shortest SOZVON_PASSWORD the server works with. The app sets 32 random characters; a password typed by
 *  hand at deploy time must be long enough that guessing it is pointless whatever the rate limits are. */
export const MIN_PASSWORD_LENGTH = 20;

/** Why the server can't check passwords at all (the 503 text), or null when SOZVON_PASSWORD is usable. */
export function passwordProblem(password: string | undefined): string | null {
  if (!password) return "SOZVON_PASSWORD is not set on the server";
  if (password.length < MIN_PASSWORD_LENGTH) {
    return `SOZVON_PASSWORD is too short: the server needs at least ${MIN_PASSWORD_LENGTH} characters. ` +
      "Set a longer one (npx wrangler secret put SOZVON_PASSWORD, or Connect Cloudflare in Sozvon)";
  }
  return null;
}

/** The key the lockout and the rate limits count an address under. IPv4: the address. IPv6: its /64 (the first
 *  four groups), because one subscriber or one cheap server owns a whole /64 and could otherwise take a fresh
 *  address, and with it a fresh counter, for every request. */
export function ipKey(ip: string): string {
  const s = ip.trim().toLowerCase().replace(/^\[|\]$/g, "").replace(/%.*$/, "");
  if (!s.includes(":")) return s;
  const mapped = /^(?:::ffff:|64:ff9b::)(\d+\.\d+\.\d+\.\d+)$/.exec(s); // an IPv4 address written as IPv6
  if (mapped) return mapped[1];
  const [head, tail] = s.split("::") as [string, string | undefined];
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = tail === undefined ? left : [...left, ...Array<string>(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

export const clientIp = (request: Request) => ipKey(request.headers.get("CF-Connecting-IP") ?? "local");

export type Check = "ok" | "wrong" | "locked" | "unset";

/** Check a password attempt from this request's IP. Wrong attempts wait FAIL_DELAY_MS before answering.
 *  A correct password writes nothing (it only clears the row when failures were recorded), so many parallel
 *  correct requests, such as a connector's, never count against the IP and can't lock it.
 *  A wrong password is counted in one statement that returns the new count, and the lock follows that count,
 *  so parallel wrong guesses can't all slip under the threshold. A burst can still get a few comparisons more
 *  than MAX_FAILURES: the ones that read the count before the others' increments landed. That is accepted, as
 *  the price of correct requests writing nothing. */
export async function checkPassword(db: D1Database, request: Request, password: string | undefined,
                                    attempt: string, now = Date.now()): Promise<Check> {
  if (!password) return "unset";
  await ensureSchema(db);
  const ip = clientIp(request);
  const row = await db.prepare(`SELECT n, since FROM auth_failures WHERE ip = ?1`).bind(ip)
    .first<{ n: number; since: number }>();
  if (row && now - row.since < WINDOW_MS && row.n >= MAX_FAILURES) return "locked";
  if (await safeEqual(attempt, password)) {
    if (row) await db.prepare(`DELETE FROM auth_failures WHERE ip = ?1`).bind(ip).run();
    return "ok";
  }
  // Rows of other IPs whose window is over go on the way.
  const [, upsert] = await db.batch<{ n: number }>([
    db.prepare(`DELETE FROM auth_failures WHERE ?1 - since >= ?2 AND ip <> ?3`).bind(now, WINDOW_MS, ip),
    db.prepare(
      `INSERT INTO auth_failures (ip, n, since) VALUES (?1, 1, ?2)
       ON CONFLICT (ip) DO UPDATE SET n = CASE WHEN ?2 - since < ?3 THEN n + 1 ELSE 1 END,
                                      since = CASE WHEN ?2 - since < ?3 THEN since ELSE ?2 END
       RETURNING n`,
    ).bind(ip, now, WINDOW_MS),
  ]);
  if ((upsert.results[0]?.n ?? 1) > MAX_FAILURES) return "locked"; // others in the same burst already used the tries
  await new Promise((r) => setTimeout(r, FAIL_DELAY_MS)); // waiting costs no CPU time
  return "wrong";
}

export const RATE_LIMIT = 20;
export const RATE_WINDOW_MS = 60 * 60 * 1000;

/** Count a request of this kind from this request's IP (an IPv6 /64 counts as one). -> false once the IP made more than `limit` of them in
 *  the window (the caller answers 429). For the unauthenticated endpoints that write to KV, whose free plan
 *  allows 1000 writes a day. Rows whose window is over are deleted on the way. */
export function rateLimit(db: D1Database, request: Request, kind: string, limit = RATE_LIMIT,
                          windowMs = RATE_WINDOW_MS, now = Date.now()): Promise<boolean> {
  return countKey(db, `${kind}:${clientIp(request)}`, limit, windowMs, now);
}

export const DAILY_BUDGET = 300;
export const DAY_MS = 24 * 3600 * 1000;
const BUDGET_KEY = "global:unauthenticated";

/** Count a request against the one daily budget all addresses share on those same endpoints. -> false once it is
 *  used up. Per-IP limits alone let many addresses together write KV 1000 times a day; then connectors that are
 *  already signed in could not refresh their tokens. With the budget, the worst a flood does is block new
 *  sign-ins until the next day. */
export function dailyBudget(db: D1Database, limit = DAILY_BUDGET, now = Date.now()): Promise<boolean> {
  return countKey(db, BUDGET_KEY, limit, DAY_MS, now);
}

async function countKey(db: D1Database, key: string, limit: number, windowMs: number, now: number): Promise<boolean> {
  await ensureSchema(db);
  const [, upsert] = await db.batch<{ n: number }>([
    // The shared budget row has a longer window than the per-IP rows: it resets itself in the upsert below.
    db.prepare(`DELETE FROM rate_limits WHERE ?1 - since >= ?2 AND key <> ?3 AND key NOT LIKE 'global:%'`).bind(now, windowMs, key),
    db.prepare(
      `INSERT INTO rate_limits (key, n, since) VALUES (?1, 1, ?2)
       ON CONFLICT (key) DO UPDATE SET n = CASE WHEN ?2 - since < ?3 THEN n + 1 ELSE 1 END,
                                       since = CASE WHEN ?2 - since < ?3 THEN since ELSE ?2 END
       RETURNING n`,
    ).bind(key, now, windowMs),
  ]);
  return (upsert.results[0]?.n ?? 1) <= limit;
}
