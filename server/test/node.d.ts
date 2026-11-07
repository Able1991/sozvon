// The few Node.js APIs the tests and vitest.config.ts use (the project has Workers types only, no @types/node).
interface ImportMeta {
  readonly url: string;
}
declare module "node:fs" {
  export function readFileSync(path: URL | string, encoding: "utf8"): string;
  export function readdirSync(path: URL | string): string[];
}
declare module "node:url" {
  export function fileURLToPath(url: URL | string): string;
}
