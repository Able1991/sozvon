// Content-Security-Policy for the sign-in page (pure, so it can be unit tested without the Workers runtime).

/** Loopback hosts the OAuth provider accepts for http redirect URIs (RFC 8252): localhost, 127.0.0.0/8, [::1]. */
export function isLoopback(hostname: string): boolean {
  const h = hostname.toLowerCase();
  if (h === "localhost" || h === "[::1]" || h === "::1") return true;
  const v4 = /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  return v4 !== null && v4.slice(1).every((octet) => Number(octet) <= 255);
}

export function csp(redirectUri: string): string {
  let origin = "";
  try {
    const u = new URL(redirectUri);
    if (u.protocol === "https:" || (u.protocol === "http:" && isLoopback(u.hostname))) origin = " " + u.origin;
  } catch { /* not a URL: 'self' only */ }
  return `default-src 'none'; style-src 'unsafe-inline'; form-action 'self'${origin}; frame-ancestors 'none'`;
}
