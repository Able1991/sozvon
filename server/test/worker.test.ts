// The whole Worker (src/index.ts) over a local D1 and KV: rate limits, and the app's KV password key.
import { readdirSync, readFileSync } from "node:fs";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { getPlatformProxy } from "wrangler";
import type { Env } from "../src/api";

vi.mock("../src/mcp", () => ({ mcpHandler: async () => new Response("mcp") }));
const { default: worker } = await import("../src/index");
const { DAILY_BUDGET, MIN_PASSWORD_LENGTH, ipKey, passwordProblem } = await import("../src/auth");

// The Sozvon app keeps the server password in this KV namespace under this key, so a second Mac can read it
// with the user's Cloudflare token. The Worker must never read or serve it.
const APP_KEY = "sozvon:password";
const SECRET = "the-app-password-in-kv-0123456789";
// Every KV key prefix @cloudflare/workers-oauth-provider 1.2.4 uses (dist/oauth-provider.js).
const PROVIDER_PREFIXES = ["grant:", "token:", "client:", "transaction:", "enterprise-jti:", "client-assertion-jti:"];

let env: Env;
const seen: { op: string; key: string }[] = [];
const ctx = { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;

beforeAll(async () => {
  const proxy = await getPlatformProxy<Env>({ persist: false });
  await proxy.env.OAUTH_KV.put(APP_KEY, SECRET);
  const kv = proxy.env.OAUTH_KV;
  // Record every key the Worker touches.
  const spy = new Proxy(kv, {
    get(target, prop) {
      const v = Reflect.get(target, prop);
      if (typeof v !== "function") return v;
      return (...args: unknown[]) => {
        const a = args[0];
        seen.push({ op: String(prop), key: typeof a === "string" ? a : `prefix=${(a as { prefix?: string } | undefined)?.prefix ?? ""}` });
        return v.apply(target, args);
      };
    },
  });
  env = { ...proxy.env, OAUTH_KV: spy, SOZVON_PASSWORD: "pw-long-enough-for-tests" };
  return () => proxy.dispose();
});

const fetchAs = (path: string, init: RequestInit & { ip?: string } = {}) =>
  worker.fetch(new Request(`https://sozvon.example.workers.dev${path}`, {
    ...init, headers: { "CF-Connecting-IP": init.ip ?? "5.5.5.5", ...(init.headers as Record<string, string> | undefined) },
  }), env, ctx);

describe("the app's password in KV", () => {
  it("can't collide with the OAuth provider's keys", () => {
    for (const p of PROVIDER_PREFIXES) expect(APP_KEY.startsWith(p) || p.startsWith("sozvon:")).toBe(false);
    const src = readFileSync(new URL("../node_modules/@cloudflare/workers-oauth-provider/dist/oauth-provider.js", import.meta.url), "utf8");
    expect(src).not.toContain("sozvon:");
  });
  it("is never read by our code", () => {
    const dir = new URL("../src/", import.meta.url);
    for (const f of readdirSync(dir).filter((n: string) => n.endsWith(".ts"))) {
      const text = readFileSync(new URL(f, dir), "utf8");
      expect(text, f).not.toMatch(/OAUTH_KV\s*\./);
      expect(text, f).not.toContain(APP_KEY);
    }
  });
  it("is never served by any route", async () => {
    const register = JSON.stringify({ client_name: APP_KEY, redirect_uris: ["https://claude.ai/api/mcp/auth_callback"] });
    const requests: [string, RequestInit?][] = [
      ["/"], ["/calls/x"], ["/sozvon:password"], ["/sozvon%3Apassword"], ["/api/health"],
      ["/api/calls", { headers: { Authorization: "Bearer pw-long-enough-for-tests" } }],
      ["/api/calls/sozvon:password", { headers: { Authorization: "Bearer pw-long-enough-for-tests" } }],
      ["/.well-known/oauth-authorization-server"], ["/.well-known/oauth-protected-resource"],
      ["/.well-known/oauth-protected-resource/mcp"],
      ["/oauth/register", { method: "POST", body: register, headers: { "Content-Type": "application/json" } }],
      [`/authorize?response_type=code&client_id=${encodeURIComponent(APP_KEY)}&redirect_uri=https://claude.ai/cb`],
      ["/oauth/token", { method: "POST", body: `grant_type=authorization_code&code=${APP_KEY}&client_id=${APP_KEY}`,
                         headers: { "Content-Type": "application/x-www-form-urlencoded" } }],
      ["/mcp", { headers: { Authorization: `Bearer ${APP_KEY}` } }],
      ["/mcp", { method: "POST", headers: { Authorization: "Bearer x:y:z" } }],
    ];
    for (const [path, init] of requests) {
      const r = await fetchAs(path, { ...init, ip: "6.6.6.6" });
      const text = await r.text();
      expect(text, path).not.toContain(SECRET);
      for (const [, v] of r.headers) expect(v, path).not.toContain(SECRET);
    }
    expect(seen.length).toBeGreaterThan(0); // the spy works: the provider used KV
    for (const { op, key } of seen) {
      expect(key.startsWith("sozvon:"), `${op} ${key}`).toBe(false);
      if (op === "list") expect(PROVIDER_PREFIXES.some((p) => key.startsWith(`prefix=${p}`)), key).toBe(true);
    }
  });
});

describe("rate limits on the endpoints that write to KV", () => {
  it("allows 20 registrations an hour per IP, then 429", async () => {
    const body = JSON.stringify({ client_name: "test", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"] });
    const register = (ip: string) => fetchAs("/oauth/register", { method: "POST", body, ip, headers: { "Content-Type": "application/json" } });
    for (let i = 0; i < 20; i++) expect((await register("7.7.7.1")).status).not.toBe(429);
    const r = await register("7.7.7.1");
    expect(r.status).toBe(429);
    expect(await r.json()).toMatchObject({ error: "too_many_requests" });
    expect((await register("7.7.7.2")).status).not.toBe(429);
  });
  it("limits /authorize the same way", async () => {
    for (let i = 0; i < 20; i++) expect((await fetchAs("/authorize?x=1", { ip: "7.7.7.3" })).status).not.toBe(429);
    expect((await fetchAs("/authorize?x=1", { ip: "7.7.7.3" })).status).toBe(429);
    expect((await fetchAs("/", { ip: "7.7.7.3" })).status).toBe(200); // other pages are not limited
  });
  it("counts a whole IPv6 /64 as one address", async () => {
    for (let i = 0; i < 20; i++) expect((await fetchAs("/authorize?x=1", { ip: `2001:db8:1:2::${i + 1}` })).status).not.toBe(429);
    expect((await fetchAs("/authorize?x=1", { ip: "2001:db8:1:2:aaaa:bbbb:cccc:dddd" })).status).toBe(429);
    expect((await fetchAs("/authorize?x=1", { ip: "2001:db8:1:3::1" })).status).not.toBe(429); // another /64
  });
  it("refuses what another page makes the browser send to /authorize, without counting it", async () => {
    const ip = "7.7.7.4";
    for (let i = 0; i < 30; i++) {
      const img = await fetchAs("/authorize?x=1", { ip, headers: { "Sec-Fetch-Dest": "image", "Sec-Fetch-Site": "cross-site" } });
      expect(img.status).toBe(400);
      const post = await fetchAs("/authorize", { ip, method: "POST", body: new URLSearchParams({ handle: "h", decision: "approve", password: "x" }),
                                                 headers: { "Sec-Fetch-Dest": "document", "Sec-Fetch-Site": "cross-site" } });
      expect(post.status).toBe(400);
    }
    expect(await env.DB.prepare("SELECT n FROM rate_limits WHERE key = 'authorize:7.7.7.4'").first()).toBeNull();
    // The owner's own navigation from claude.ai still gets through.
    const nav = await fetchAs("/authorize?x=1", { ip, headers: { "Sec-Fetch-Dest": "document", "Sec-Fetch-Site": "cross-site" } });
    expect(nav.status).not.toBe(429);
    expect(await env.DB.prepare("SELECT n FROM rate_limits WHERE key = 'authorize:7.7.7.4'").first()).toEqual({ n: 1 });
  });
  it("has one daily budget across all addresses, which per-IP cleanup never resets", async () => {
    const now = Date.now();
    await env.DB.prepare("INSERT OR REPLACE INTO rate_limits VALUES ('global:unauthenticated', ?1, ?2)").bind(DAILY_BUDGET - 1, now - 2 * 3600 * 1000).run();
    expect((await fetchAs("/authorize?x=1", { ip: "7.7.8.1" })).status).not.toBe(429); // the last one of the day
    const r = await fetchAs("/authorize?x=1", { ip: "7.7.8.2" });
    expect(r.status).toBe(429);
    expect(await r.text()).toContain("today");
    const body = JSON.stringify({ client_name: "test", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"] });
    const reg = await fetchAs("/oauth/register", { method: "POST", body, ip: "7.7.8.3", headers: { "Content-Type": "application/json" } });
    expect(reg.status).toBe(429);
    expect((await fetchAs("/api/health", { ip: "7.7.8.2" })).status).toBe(200); // the rest of the server works
    // A day after the budget's first request it starts again.
    await env.DB.prepare("UPDATE rate_limits SET since = ?1 WHERE key = 'global:unauthenticated'").bind(now - 25 * 3600 * 1000).run();
    expect((await fetchAs("/authorize?x=1", { ip: "7.7.8.2" })).status).not.toBe(429);
  });
});

describe("a password too short to be safe", () => {
  it("is refused everywhere with a clear message", async () => {
    const weak = { ...env, SOZVON_PASSWORD: "only-19-characters!" };
    const get = (path: string, headers: Record<string, string> = {}) =>
      worker.fetch(new Request(`https://sozvon.example.workers.dev${path}`, { headers: { "CF-Connecting-IP": "7.7.9.1", ...headers } }), weak, ctx);
    const api = await get("/api/calls", { Authorization: "Bearer only-19-characters!" });
    expect(api.status).toBe(503);
    expect(((await api.json()) as { error: string }).error).toContain("at least 20 characters");
    const signIn = await get("/authorize?x=1");
    expect(signIn.status).toBe(503);
    expect(await signIn.text()).toContain("at least 20 characters");
    expect((await get("/api/health")).status).toBe(200);
  });
});

describe("ipKey", () => {
  it("keeps IPv4 and reduces IPv6 to its /64", () => {
    expect(ipKey("203.0.113.7")).toBe("203.0.113.7");
    expect(ipKey("local")).toBe("local");
    expect(ipKey("2001:db8:1:2:3:4:5:6")).toBe("2001:db8:1:2::/64");
    expect(ipKey("2001:0DB8:0001:0002::1")).toBe("2001:db8:1:2::/64");
    expect(ipKey("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(ipKey("2001:db8:0:0:ffff::")).toBe("2001:db8:0:0::/64");
    expect(ipKey("::1")).toBe("0:0:0:0::/64");
    expect(ipKey("::ffff:203.0.113.7")).toBe("203.0.113.7");
  });
});

describe("passwordProblem", () => {
  it("accepts what the app and the docs generate, refuses short ones", () => {
    expect(passwordProblem(undefined)).toContain("not set");
    expect(passwordProblem("")).toContain("not set");
    expect(passwordProblem("x".repeat(MIN_PASSWORD_LENGTH - 1))).toContain("too short");
    expect(passwordProblem("x".repeat(MIN_PASSWORD_LENGTH))).toBeNull();
    expect(MIN_PASSWORD_LENGTH).toBeLessThanOrEqual(32); // the app's 32 characters and `openssl rand -base64 24` pass
  });
});
