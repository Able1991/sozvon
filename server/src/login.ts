// The OAuth sign-in page at /authorize: one password field (SOZVON_PASSWORD), Allow or Deny.
import { type AuthRequest, AuthorizationError, CimdFetchError, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { type Env } from "./api";
import { checkPassword, passwordTag } from "./auth";
import { csp } from "./csp";
import { sourceName } from "./tools";

export const OWNER = "owner"; // single user: every grant belongs to the person who deployed the server

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const SECURITY_HEADERS = {
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "no-store",
};

const STYLE = `body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:26rem;margin:10vh auto;padding:0 16px;color:#1d1d1f;background:#fff}
@media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}input{background:#2c2c2e;color:inherit}}
h1{font-size:1.4rem}input[type=password]{width:100%;box-sizing:border-box;padding:.6rem;font:inherit;border:1px solid #888;border-radius:8px}
button{font:inherit;padding:.5rem 1.2rem;border-radius:8px;border:1px solid #888;margin:1rem .5rem 0 0}
button[value=approve]{background:#0a84ff;color:#fff;border-color:#0a84ff}.err{color:#d70015}.note{color:#888;font-size:.9rem}`;

export function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>${STYLE}</style></head><body>${body}</body></html>`;
}

function loginForm(d: { clientName: string; redirectHost: string; redirectIsLoopback: boolean }, handle: string,
                   message = ""): string {
  return page("Sozvon sign-in", `<h1>Connect ${esc(d.clientName)} to your calls</h1>
<p>${esc(d.clientName)} will be able to read and search the calls on this server and add notes to them. Access goes to <strong>${esc(d.redirectHost)}</strong>.</p>
${d.redirectIsLoopback ? "<p><strong>This sends access to an app on this computer.</strong> Continue only if you just started connecting from it.</p>" : ""}
${message ? `<p class="err">${esc(message)}</p>` : ""}
<form method="post" action="/authorize">
<input type="hidden" name="handle" value="${esc(handle)}">
<label for="pw">Password of this Sozvon server</label>
<input id="pw" type="password" name="password" autocomplete="current-password" autofocus>
<button name="decision" value="approve">Allow</button><button name="decision" value="deny">Deny</button>
</form>
<p class="note">This server runs in your own Cloudflare account: your calls are not sent to the Sozvon developers or any shared service.</p>`);
}

/** The form for an authorization request. carry: headers of a consumed consent (its cookie cleanup) to send too. */
async function showForm(oauth: OAuthHelpers, authRequest: AuthRequest, message = "", status = 200,
                        carry?: Headers): Promise<Response> {
  const details = await oauth.describeConsent(authRequest);
  const consent = await oauth.beginConsent(authRequest);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) consent.headers.set(k, v);
  for (const c of carry?.getSetCookie() ?? []) consent.headers.append("Set-Cookie", c);
  // Chrome applies form-action to the redirect after the form is posted, so the client's callback
  // origin (claude.ai, chatgpt.com, ...; already validated by the OAuth provider) must be allowed too.
  consent.headers.set("Content-Security-Policy", csp(authRequest.redirectUri));
  return new Response(loginForm(details, consent.handle, message), { status, headers: consent.headers });
}

const plain = (status: number, message: string) =>
  new Response(page("Sozvon", `<p>${esc(message)}</p>`), { status, headers: SECURITY_HEADERS });

export async function authorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER!;
  try {
    if (request.method === "GET") return await showForm(oauth, await oauth.parseAuthRequest(request));
    if (request.method !== "POST") return plain(405, "Method not allowed.");
    const form = await request.formData();
    const handle = String(form.get("handle") ?? "");
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    // The handle and its binding cookie first (a __Host- cookie set when this browser opened the form): a page
    // on another site can't post here with it, so it can't spend this IP's password attempts and lock the owner
    // out (the lockout covers /api too). This uses the handle up.
    const approved = await oauth.approveConsent(request, handle);
    const check = await checkPassword(env.DB, request, env.SOZVON_PASSWORD, String(form.get("password") ?? ""));
    if (check !== "ok") {
      const message = check === "unset" ? "SOZVON_PASSWORD is not set on this server yet."
        : check === "locked" ? "Too many wrong passwords. Try again in 15 minutes." : "Wrong password.";
      // Show the form again for the same authorization request, with a fresh consent handle.
      return await showForm(oauth, approved.request, message, check === "locked" ? 429 : 401, approved.headers);
    }
    // The connector's name becomes the source of the notes it adds ("claude", "chatgpt").
    const client = sourceName((await oauth.describeConsent(approved.request)).clientName);
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: OWNER,
      metadata: {},
      scope: approved.request.scope,
      props: { origin: new URL(request.url).origin, pw: await passwordTag(env.SOZVON_PASSWORD!), client },
    });
    approved.headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (e) {
    if (e instanceof AuthorizationError && e.redirectTo) return Response.redirect(e.redirectTo, 302);
    if (e instanceof AuthorizationError) return plain(400, e.description ?? "Invalid sign-in request. Start connecting again.");
    if (e instanceof CimdFetchError) return plain(400, "This app could not be verified.");
    throw e;
  }
}
