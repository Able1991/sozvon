// A real local D1 (SQLite with FTS5, through Miniflare) for tests, empty for every test file.
import { getPlatformProxy } from "wrangler";
import { afterAll } from "vitest";
import type { Env } from "../src/api";

export async function localD1(): Promise<D1Database> {
  const proxy = await getPlatformProxy<Env>({ persist: false });
  afterAll(() => proxy.dispose());
  return proxy.env.DB;
}
