// Sozvon server: your calls on your own Cloudflare account, for Claude and ChatGPT connectors.
//   /api/*      sync API for the Sozvon app (bearer SOZVON_PASSWORD)
//   /mcp        MCP over Streamable HTTP, OAuth 2.1 (sign-in with SOZVON_PASSWORD)
//   /authorize  the sign-in page; discovery, token and registration endpoints come from the OAuth provider
import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { type Env, handleApi } from "./api";
import { passwordTag, rateLimit } from "./auth";
import { authorize, page } from "./login";
import { mcpHandler } from "./mcp";

const mcpApi = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    // A grant made with an old password stops working when the password changes.
    const props = ctx.props as { pw?: string } | undefined;
    if (!env.SOZVON_PASSWORD || props?.pw !== await passwordTag(env.SOZVON_PASSWORD)) {
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
    });
    providers.set(origin, p);
  }
  return p;
}

// Unauthenticated endpoints that write to KV (a client record, a consent transaction): rate limited per IP,
// so nobody can burn the free plan's 1000 KV writes a day.
function limited(request: Request, pathname: string): string | null {
  if (pathname === "/oauth/register" && request.method === "POST") return "register";
  if (pathname === "/authorize") return "authorize";
  return null;
}

const TOO_MANY = "Too many sign-in attempts from this network. Try again in an hour.";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/api" || url.pathname.startsWith("/api/")) return handleApi(request, env);
    const kind = limited(request, url.pathname);
    if (kind && !(await rateLimit(env.DB, request, kind))) {
      return kind === "register"
        ? Response.json({ error: "too_many_requests", error_description: TOO_MANY }, { status: 429, headers: { "Retry-After": "3600" } })
        : new Response(page("Sozvon", `<p>${TOO_MANY}</p>`), {
            status: 429, headers: { "Content-Type": "text/html; charset=utf-8", "Retry-After": "3600", "Cache-Control": "no-store" } });
    }
    if (url.pathname === "/.well-known/oauth-protected-resource") {
      // RFC 9728 puts it at .../oauth-protected-resource/mcp (served by the provider); some clients look at the root.
      url.pathname += "/mcp";
      return provider(url.origin).fetch(new Request(url, request), env, ctx);
    }
    return provider(url.origin).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
