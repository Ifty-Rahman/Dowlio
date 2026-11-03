import { hostOf } from "./catching.js";

export const MAX_COOKIE_BYTES = 100000;

export function startCookies({ chrome }) {
  async function cookiesFor(url) {
    if (!hostOf(url ?? "")) return undefined;
    const found = await chrome.cookies
      .getAll({ url, partitionKey: {} })
      .then((all) => all.filter((cookie) => keptForSite(cookie.partitionKey, url)))
      .catch(() => chrome.cookies.getAll({ url }))
      .catch(() => []);
    const kept = [];
    let bytes = 0;
    for (const cookie of found) {
      const { name, value } = cookie;
      bytes += name.length + value.length + (cookie.domain?.length ?? 0) + (cookie.path?.length ?? 0) + 80;
      if (bytes > MAX_COOKIE_BYTES) break;
      const entry = { name, value };
      if (typeof cookie.domain === "string") entry.domain = cookie.domain;
      if (typeof cookie.path === "string") entry.path = cookie.path;
      for (const flag of ["hostOnly", "secure", "httpOnly"]) {
        if (typeof cookie[flag] === "boolean") entry[flag] = cookie[flag];
      }
      kept.push(entry);
    }
    return kept.length ? kept : undefined;
  }

  return { cookiesFor };
}

function keptForSite(partitionKey, url) {
  if (!partitionKey?.topLevelSite) return true;
  if (partitionKey.hasCrossSiteAncestor) return false;
  const site = new URL(partitionKey.topLevelSite);
  const link = new URL(url);
  return site.protocol === link.protocol && (link.hostname === site.hostname || link.hostname.endsWith(`.${site.hostname}`));
}
