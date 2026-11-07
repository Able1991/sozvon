import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "cloudflare:workers": fileURLToPath(new URL("./test/cloudflare-workers.stub.ts", import.meta.url)) } },
  test: {
    include: ["test/**/*.test.ts"], testTimeout: 30_000, hookTimeout: 60_000,
    // The OAuth provider imports "cloudflare:workers": inlined, so the alias above applies to it.
    server: { deps: { inline: ["@cloudflare/workers-oauth-provider"] } },
  },
});
