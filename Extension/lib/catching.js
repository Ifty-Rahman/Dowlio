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
  const taken = new Map();

  function rememberTaken(url, details) {
    for (const [link, entry] of taken) if (now() - entry.at > HAND_BACK_MARK_LIFETIME) taken.delete(link);
    taken.set(sameLink(url), { ...details, at: now() });
  }

  function takenFor(url) {
    const key = sameLink(url);
    const entry = taken.get(key);
    taken.delete(key);
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

  function skipped(item) {
    const source = item.finalUrl || item.url;
    if (item.byExtensionId === chrome.runtime.id || wasHandedBack(item.url)) return true;
    if (!isWebLink(item.url) || !isWebLink(source)) return true;
    return Boolean(item.incognito);
  }

  function letGo(item) {
    const cancelled = downloads.cancel(item.id).catch(() => {});
    return cancelled.then(() => downloads.erase({ id: item.id }).catch(() => {}));
  }

  async function offer(item, seen) {
    const source = item.finalUrl || item.url;
    const cookies = await link.cookiesFor?.(source);
    const reply = await link.request(
      "catch.offer",
      {
        url: item.url,
        finalUrl: source,
        referrer: item.referrer || seen.referrer || undefined,
        mime: item.mime || undefined,
        totalBytes: item.totalBytes > 0 ? item.totalBytes : undefined,
        userAgent: seen.userAgent || navigator?.userAgent,
        cookies,
        request: seen.request,
      },
      CATCH_TIMEOUT,
    );
    if (reply?.type === "catch.accepted") {
      link.release?.(reply.requestId);
      rememberTaken(item.url, { host: hostOf(source), hadCookies: Boolean(cookies), request: seen.request });
      await chrome.storage.local.remove("lastDecline");
      return;
    }
    const reason = reply?.type === "catch.declined" ? reply.reason : "noAnswer";
    await chrome.storage.local.set({ lastDecline: { host: hostOf(source), reason, hadCookies: Boolean(cookies), at: Date.now() } });
    await startInBrowser(item.url, seen.request);
  }

  async function takeOnceConnected(item, seen) {
    if (!(await link.whenConnected(LINK_WAIT))) return;
    const { catches, neverCatch } = await link.preferences();
    if (!catches || isNeverCaught(item, neverCatch)) return;
    await letGo(item);
    await offer(item, seen);
  }

  function take(item) {
    if (skipped(item)) return;
    const seen = requests.requestFor(item.finalUrl, item.url);
    const preferences = link.isConnected() ? link.preferencesNow?.() : null;
    if (!preferences) return takeOnceConnected(item, seen);
    if (!preferences.catches || isNeverCaught(item, preferences.neverCatch)) return;
    const gone = letGo(item);
    return gone.then(() => offer(item, seen));
  }

  downloads.onCreated.addListener((item) => {
    take(item);
  });

  return {
    async downloadInBrowser(url, reason) {
      if (!isWebLink(url)) return;
      const catchOf = takenFor(url);
      if (reason && catchOf) {
        await chrome.storage.local.set({ lastDecline: { host: catchOf.host, reason, hadCookies: catchOf.hadCookies, at: Date.now() } });
      }
      await startInBrowser(url, catchOf?.request);
    },
  };
}
