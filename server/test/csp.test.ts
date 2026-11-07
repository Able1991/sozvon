import { describe, expect, it } from "vitest";
import { csp, isLoopback } from "../src/csp";

describe("login CSP", () => {
  it("allows the client's callback origin in form-action", () => {
    expect(csp("https://claude.ai/api/mcp/auth_callback")).toContain("form-action 'self' https://claude.ai;");
    expect(csp("https://chatgpt.com/connector_platform_oauth_redirect")).toContain("form-action 'self' https://chatgpt.com;");
    expect(csp("javascript:alert(1)")).toContain("form-action 'self';");
    expect(csp("not a url")).toContain("form-action 'self';");
  });
});

describe("login CSP for apps on this computer", () => {
  it("allows every loopback form the OAuth provider accepts", () => {
    for (const uri of ["http://localhost:3000/cb", "http://127.0.0.1:5555/cb", "http://127.1.2.3/cb", "http://[::1]:8080/cb"]) {
      expect(csp(uri)).toContain(`form-action 'self' ${new URL(uri).origin};`);
    }
    for (const uri of ["http://example.com/cb", "http://127.0.0.1.evil.com/cb", "http://127.0.0.256/cb", "http://10.0.0.1/cb"]) {
      expect(csp(uri)).toContain("form-action 'self';");
    }
    expect(isLoopback("LOCALHOST")).toBe(true);
  });
});
