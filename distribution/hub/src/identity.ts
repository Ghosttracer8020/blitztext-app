// Identity as set by `tailscale serve`: it strips client-sent Tailscale-User-*
// headers and sets the device owner's login. Only presence matters here – there is
// no per-person allowlist, every Tailnet member may fetch updates.

/** Returns the trimmed login, or null when the header is missing or blank. */
export function readLogin(header: (name: string) => string | undefined | null): string | null {
  const raw = header('Tailscale-User-Login');
  if (raw === undefined || raw === null) return null;
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return cleaned === '' ? null : cleaned.slice(0, 320);
}
