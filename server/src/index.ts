// Sozvon server: your calls on your own Cloudflare account, for Claude and ChatGPT connectors.
//   /api/*      sync API for the Sozvon app (bearer SOZVON_PASSWORD)
//   /mcp        MCP over Streamable HTTP, OAuth 2.1 (sign-in with SOZVON_PASSWORD)
//   /authorize  the sign-in page; discovery, token and registration endpoints come from the OAuth provider
import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { type Env, handleApi } from "./api";
import { dailyBudget, passwordProblem, passwordTag, rateLimit } from "./auth";
import { authorize, page } from "./login";
import { mcpHandler } from "./mcp";

const mcpApi = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    // A grant made with an old password stops working when the password changes.
    const props = ctx.props as { pw?: string } | undefined;
    if (passwordProblem(env.SOZVON_PASSWORD) || props?.pw !== await passwordTag(env.SOZVON_PASSWORD!)) {
      return Response.json({ error: "invalid_token", error_description: "Sign in again" }, {
        status: 401, headers: { "WWW-Authenticate": 'Bearer error="invalid_token"' },
      });
    }
    return mcpHandler(request, env, ctx);
  },
};

const site = {
  async fetch(request: Request, env: Env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/authorize") return authorize(request, env);
    if (pathname === "/" || pathname.startsWith("/calls/")) {
      // Citation links of ChatGPT point here: nothing about the call is shown without signing in.
      return new Response(page("Sozvon", `<h1>Sozvon</h1><p>This is a private Sozvon server. Its calls are available only
to the connectors its owner signed in, and in the Sozvon app on the owner's Mac.</p>`), {
        headers: { "Content-Type": "text/html; charset=utf-8", "X-Robots-Tag": "noindex" },
      });
    }
    return new Response("Not found", { status: 404 });
  },
};

// The resource every token is bound to is this deployment's own /mcp URL, so the provider is built per origin.
const providers = new Map<string, OAuthProvider<Env>>();

function provider(origin: string): OAuthProvider<Env> {
  let p = providers.get(origin);
  if (!p) {
    p = new OAuthProvider<Env>({
      apiRoute: "/mcp",
      apiHandler: mcpApi,
      defaultHandler: site,
      authorizeEndpoint: "/authorize",
      tokenEndpoint: "/oauth/token",
      clientRegistrationEndpoint: "/oauth/register",
      clientIdMetadataDocumentEnabled: true,
      resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin], resource_name: "Sozvon" },
      refreshTokenTTL: 90 * 24 * 3600,
      // A registration nobody uses expires; the provider renews one that still exchanges tokens.
      clientRegistrationTTL: 90 * 24 * 3600,
    });
    providers.set(origin, p);
  }
  return p;
}

// Unauthenticated endpoints that write to KV (a client record, a consent transaction): rate limited per IP
// (per /64 for IPv6) and by one daily budget across all addresses, so nobody can burn the free plan's
// 1000 KV writes a day.
function limited(request: Request, pathname: string): string | null {
  if (pathname === "/oauth/register" && request.method === "POST") return "register";
  if (pathname === "/authorize") return "authorize";
  return null;
}

const TOO_MANY = "Too many sign-in attempts from this network. Try again in an hour.";
const TOO_MANY_TODAY = "Too many sign-in attempts on this server today. Try again tomorrow.";

/** Is this /authorize request one a browser makes on behalf of another page, not a sign-in? The sign-in page is
 *  opened as a top-level navigation and its form is posted from this origin. An <img>, a fetch, a frame or a form
 *  on another site is none of that; browsers say so in Sec-Fetch-*. Such a request is refused before it is
 *  counted or written to KV, so a page the owner visits can't use up the owner's own sign-in limit.
 *  Clients that send no Sec-Fetch-* headers (not browsers) are counted as before. */
export function foreignAuthorize(request: Request): boolean {
  if (request.method === "GET") {
    const dest = request.headers.get("Sec-Fetch-Dest");
    return dest !== null && dest !== "document";
  }
  const from = request.headers.get("Sec-Fetch-Site");
  return from !== null && from !== "same-origin";
}

function tooMany(kind: string, message: string, retryAfter: number): Response {
  const headers = { "Retry-After": String(retryAfter), "Cache-Control": "no-store" };
  return kind === "register"
    ? Response.json({ error: "too_many_requests", error_description: message }, { status: 429, headers })
    : new Response(page("Sozvon", `<p>${message}</p>`), {
        status: 429, headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/api" || url.pathname.startsWith("/api/")) return handleApi(request, env);
    const kind = limited(request, url.pathname);
    if (kind === "authorize" && foreignAuthorize(request)) {
      return new Response("Open this page in the browser to sign in.", { status: 400, headers: { "Cache-Control": "no-store" } });
    }
    if (kind) {
      // The address's own limit first: requests over it never touch the shared budget.
      if (!(await rateLimit(env.DB, request, kind))) return tooMany(kind, TOO_MANY, 3600);
      if (!(await dailyBudget(env.DB))) return tooMany(kind, TOO_MANY_TODAY, 24 * 3600);
    }
    if (url.pathname === "/.well-known/oauth-protected-resource") {
      // RFC 9728 puts it at .../oauth-protected-resource/mcp (served by the provider); some clients look at the root.
      url.pathname += "/mcp";
      return provider(url.origin).fetch(new Request(url, request), env, ctx);
    }
    return provider(url.origin).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
