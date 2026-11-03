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
    for (const { name, value } of found) {
      bytes += name.length + value.length + 40;
      if (bytes > MAX_COOKIE_BYTES) break;
      kept.push({ name, value });
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
