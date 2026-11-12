// The sign-in POST: the consent handle and its browser cookie are checked before the password.
import { AuthorizationError, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { beforeAll, describe, expect, it } from "vitest";
import type { Env } from "../src/api";
import { ensureSchema } from "../src/db";
import { authorize } from "../src/login";
import { localD1 } from "./d1";

const AUTH_REQUEST = { responseType: "code", clientId: "c1", redirectUri: "https://claude.ai/cb", scope: [], state: "s" };

function fakeOAuth(validHandle: string) {
  const calls: string[] = [];
  const oauth = {
    async approveConsent(_req: Request, handle: string) {
      calls.push(`approve ${handle}`);
      if (handle !== validHandle) throw new AuthorizationError("invalid_request", { description: "This authorization was not started in this browser; start again" });
      const headers = new Headers();
      headers.append("Set-Cookie", "__Host-consent-old=; Max-Age=0");
      return { request: AUTH_REQUEST, headers };
    },
    async describeConsent() {
      return { clientName: "Claude", redirectHost: "claude.ai", redirectIsLoopback: false, scope: [] };
    },
    async beginConsent() {
      calls.push("begin");
      const headers = new Headers();
      headers.append("Set-Cookie", "__Host-consent-new=1");
      return { handle: "fresh-handle", headers };
    },
    async completeAuthorization() {
      calls.push("complete");
      return { redirectTo: "https://claude.ai/cb?code=x" };
    },
  };
  return { oauth: oauth as unknown as OAuthHelpers, calls };
}

describe("sign-in POST", () => {
  let db: D1Database;
  beforeAll(async () => {
    db = await localD1();
    await ensureSchema(db);
  });
  const post = (env: Env, fields: Record<string, string>, ip: string) =>
    authorize(new Request("https://sozvon.example/authorize", {
      method: "POST", body: new URLSearchParams(fields), headers: { "CF-Connecting-IP": ip },
    }), env);
  const failures = async (ip: string) =>
    (await db.prepare("SELECT n FROM auth_failures WHERE ip = ?1").bind(ip).first<{ n: number }>())?.n ?? 0;

  it("a post from another site (no consent cookie) never counts as a wrong password", async () => {
    const { oauth, calls } = fakeOAuth("good");
    const env = { DB: db, OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw-long-enough-for-tests", OAUTH_PROVIDER: oauth };
    for (let i = 0; i < 12; i++) {
      const r = await post(env, { handle: "forged", decision: "approve", password: "guess" }, "3.3.3.3");
      expect(r.status).toBe(400);
    }
    expect(await failures("3.3.3.3")).toBe(0);
    expect(calls.every((c) => c === "approve forged")).toBe(true);
  });
  it("a wrong password in the real form counts and shows a fresh form", async () => {
    const { oauth, calls } = fakeOAuth("good");
    const env = { DB: db, OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw-long-enough-for-tests", OAUTH_PROVIDER: oauth };
    const r = await post(env, { handle: "good", decision: "approve", password: "wrong" }, "3.3.3.4");
    expect(r.status).toBe(401);
    const html = await r.text();
    expect(html).toContain("Wrong password.");
    expect(html).toContain('value="fresh-handle"');
    expect(r.headers.getSetCookie()).toEqual(expect.arrayContaining(["__Host-consent-new=1", "__Host-consent-old=; Max-Age=0"]));
    expect(await failures("3.3.3.4")).toBe(1);
    expect(calls).toEqual(["approve good", "begin"]);
  });
  it("the right password completes the sign-in", async () => {
    const { oauth, calls } = fakeOAuth("good");
    const env = { DB: db, OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw-long-enough-for-tests", OAUTH_PROVIDER: oauth };
    const r = await post(env, { handle: "good", decision: "approve", password: "pw-long-enough-for-tests" }, "3.3.3.5");
    expect(r.status).toBe(302);
    expect(r.headers.get("Location")).toBe("https://claude.ai/cb?code=x");
    expect(calls).toEqual(["approve good", "complete"]);
  });
});
