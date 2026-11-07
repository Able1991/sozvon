// "cloudflare:workers" outside the Workers runtime (vitest.config.ts aliases it here): what the OAuth provider
// and mcp.ts import. Tests that need bindings pass them explicitly.
export class WorkerEntrypoint {
  constructor(public ctx?: unknown, public env?: unknown) {}
}
export const env = {};
