import { startWatchingRequests } from "./requests.js";

export const CATCH_TIMEOUT = 15000;
export const LINK_WAIT = 3000;
export const HAND_BACK_MARK_LIFETIME = 60000;

function isWebLink(link) {
  return /^https?:/i.test(link ?? "");
}

function sameLink(url) {
  try {
    return new URL(url).href;
  } catch {
    return url;
  }
}

export function hostOf(url) {
  try {
    return new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function matchesSite(host, sites) {
  return sites.some((site) => host === site || host.endsWith(`.${site}`));
}

function isNeverCaught(item, sites) {
  return [item.url, item.finalUrl, item.referrer].map(hostOf).some((host) => host && matchesSite(host, sites));
}

export function startCatching({ chrome, link, navigator, now = Date.now }) {
  const downloads = chrome.downloads;
  const requests = startWatchingRequests({ chrome, now });
  const handedBack = new Map();
  const caught = new Map();

  function rememberCaught(url, details) {
    for (const [earlier, entry] of caught) if (now() - entry.at > HAND_BACK_MARK_LIFETIME) caught.delete(earlier);
    caught.set(sameLink(url), { ...details, at: now() });
  }

  function caughtFrom(url) {
    const key = sameLink(url);
    const entry = caught.get(key);
    caught.delete(key);
    return entry && now() - entry.at < HAND_BACK_MARK_LIFETIME ? entry : undefined;
  }

  function sentAgain(url, request) {
    if (request?.method !== "POST" || !request.body) return { url };
    const body = new TextDecoder().decode(Uint8Array.from(atob(request.body), (char) => char.charCodeAt(0)));
    const headers = request.headers.filter(({ name }) => name.toLowerCase() === "content-type");
    return { url, method: "POST", body, headers };
  }

  function wasHandedBack(url) {
    const key = sameLink(url);
    const markedAt = handedBack.get(key);
    handedBack.delete(key);
    return markedAt !== undefined && now() - markedAt < HAND_BACK_MARK_LIFETIME;
  }

  function startInBrowser(url, request) {
    handedBack.set(sameLink(url), now());
    return downloads.download(sentAgain(url, request)).catch(() => handedBack.delete(sameLink(url)));
  }

  function noteWhyItStayed(host, reason, hadCookies) {
    return chrome.storage.local.set({ lastDecline: { host, reason, hadCookies, at: now() } }).catch(() => {});
  }

  function staysInBrowser(item, browserRequest) {
    const source = item.finalUrl || item.url;
    if (item.byExtensionId === chrome.runtime.id || wasHandedBack(item.url)) return true;
    if (!isWebLink(item.url) || !isWebLink(source)) return true;
    return Boolean(item.incognito) || browserRequest.unsendable;
  }

  function removeFromBrowser(item) {
    const cancelled = downloads.cancel(item.id).catch(() => {});
    return cancelled.then(() => downloads.erase({ id: item.id }).catch(() => {}));
  }

  async function offer(item, browserRequest) {
    const source = item.finalUrl || item.url;
    let cookies;
    let reason = "error";
    try {
      cookies = await link.cookiesFor?.(source);
      const reply = await link.request(
        "catch.offer",
        {
          url: item.url,
          finalUrl: source,
          referrer: item.referrer || browserRequest.referrer || undefined,
          mime: item.mime || undefined,
          totalBytes: item.totalBytes > 0 ? item.totalBytes : undefined,
          userAgent: browserRequest.userAgent || navigator?.userAgent,
          cookies,
          request: browserRequest.request,
        },
        CATCH_TIMEOUT,
      );
      if (reply?.type === "catch.accepted") {
        link.release?.(reply.requestId);
        rememberCaught(item.url, { host: hostOf(source), hadCookies: Boolean(cookies), request: browserRequest.request });
        await chrome.storage.local.remove("lastDecline").catch(() => {});
        return;
      }
      reason = reply?.type === "catch.declined" ? reply.reason : "noAnswer";
    } catch {
      reason = "error";
    }
    await startInBrowser(item.url, browserRequest.request);
    await noteWhyItStayed(hostOf(source), reason, Boolean(cookies));
  }

  async function catchOnceConnected(item, browserRequest) {
    if (!(await link.whenConnected(LINK_WAIT))) return;
    const { catches, neverCatch } = await link.preferences();
    if (!catches || isNeverCaught(item, neverCatch)) return;
    await removeFromBrowser(item);
    await offer(item, browserRequest);
  }

  function catchDownload(item) {
    const browserRequest = requests.requestFor(item.finalUrl, item.url);
    if (staysInBrowser(item, browserRequest)) return Promise.resolve();
    const preferences = link.isConnected() ? link.preferencesNow?.() : null;
    if (!preferences) return catchOnceConnected(item, browserRequest);
    if (!preferences.catches || isNeverCaught(item, preferences.neverCatch)) return Promise.resolve();
    return removeFromBrowser(item).then(() => offer(item, browserRequest));
  }

  downloads.onCreated.addListener((item) => {
    catchDownload(item).catch(() => {});
  });

  return {
    async downloadInBrowser(url, reason) {
      if (!isWebLink(url)) return;
      const earlier = caughtFrom(url);
      await startInBrowser(url, earlier?.request);
      if (reason && earlier) await noteWhyItStayed(earlier.host, reason, earlier.hadCookies);
    },
  };
}
