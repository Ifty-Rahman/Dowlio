import { hostOf, matchesSite } from "./catching.js";

export const MAX_COOKIE_BYTES = 100000;

export function startSignIn({ chrome, preferences }) {
  async function cookiesFor(url) {
    const host = hostOf(url ?? "");
    const { signIn, noSignIn } = await preferences();
    if (!host || !signIn || matchesSite(host, noSignIn)) return undefined;
    const found = await chrome.cookies.getAll({ url }).catch(() => []);
    const kept = [];
    let bytes = 0;
    for (const { name, value } of found) {
      bytes += name.length + value.length + 40;
      if (bytes > MAX_COOKIE_BYTES) break;
      kept.push({ name, value });
    }
    return kept.length ? kept : undefined;
  }

  return { cookiesFor };
}
