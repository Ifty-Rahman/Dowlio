import { hostOf } from "./catching.js";

export const MAX_COOKIE_BYTES = 100000;

export function startCookies({ chrome }) {
  async function cookiesFor(url) {
    if (!hostOf(url ?? "")) return undefined;
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
