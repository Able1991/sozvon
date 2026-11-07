// The one secret, SOZVON_PASSWORD: the app sends it as a bearer token, the sign-in page asks for it.
// Compared in constant time; wrong attempts are slowed down and, per IP, locked out for a while.
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

export const clientIp = (request: Request) => request.headers.get("CF-Connecting-IP") ?? "local";

export type Check = "ok" | "wrong" | "locked" | "unset";

/** Check a password attempt from this request's IP. Wrong attempts wait FAIL_DELAY_MS before answering. */
export async function checkPassword(db: D1Database, request: Request, password: string | undefined,
                                    attempt: string, now = Date.now()): Promise<Check> {
  if (!password) return "unset";
  await ensureSchema(db);
  const ip = clientIp(request);
  const row = await db.prepare(`SELECT n, since FROM auth_failures WHERE ip = ?1`).bind(ip)
    .first<{ n: number; since: number }>();
  const fresh = row && now - row.since < WINDOW_MS;
  if (fresh && row.n >= MAX_FAILURES) return "locked";
  if (await safeEqual(attempt, password)) {
    if (row) await db.prepare(`DELETE FROM auth_failures WHERE ip = ?1`).bind(ip).run();
    return "ok";
  }
  // A correct password never gets here, so it is never counted. Rows of other IPs whose window is over go.
  await db.batch([
    db.prepare(`DELETE FROM auth_failures WHERE ?1 - since >= ?2 AND ip <> ?3`).bind(now, WINDOW_MS, ip),
    db.prepare(
      `INSERT INTO auth_failures (ip, n, since) VALUES (?1, 1, ?2)
       ON CONFLICT (ip) DO UPDATE SET n = CASE WHEN ?2 - since < ?3 THEN n + 1 ELSE 1 END,
                                      since = CASE WHEN ?2 - since < ?3 THEN since ELSE ?2 END`,
    ).bind(ip, now, WINDOW_MS),
  ]);
  await new Promise((r) => setTimeout(r, FAIL_DELAY_MS)); // waiting costs no CPU time
  return "wrong";
}

export const RATE_LIMIT = 20;
export const RATE_WINDOW_MS = 60 * 60 * 1000;

/** Count a request of this kind from this request's IP. -> false once the IP made more than `limit` of them in
 *  the window (the caller answers 429). For the unauthenticated endpoints that write to KV, whose free plan
 *  allows 1000 writes a day. Rows whose window is over are deleted on the way. */
export async function rateLimit(db: D1Database, request: Request, kind: string, limit = RATE_LIMIT,
                                windowMs = RATE_WINDOW_MS, now = Date.now()): Promise<boolean> {
  await ensureSchema(db);
  const key = `${kind}:${clientIp(request)}`;
  const [, upsert] = await db.batch<{ n: number }>([
    db.prepare(`DELETE FROM rate_limits WHERE ?1 - since >= ?2 AND key <> ?3`).bind(now, windowMs, key),
    db.prepare(
      `INSERT INTO rate_limits (key, n, since) VALUES (?1, 1, ?2)
       ON CONFLICT (key) DO UPDATE SET n = CASE WHEN ?2 - since < ?3 THEN n + 1 ELSE 1 END,
                                       since = CASE WHEN ?2 - since < ?3 THEN since ELSE ?2 END
       RETURNING n`,
    ).bind(key, now, windowMs),
  ]);
  return (upsert.results[0]?.n ?? 1) <= limit;
}
