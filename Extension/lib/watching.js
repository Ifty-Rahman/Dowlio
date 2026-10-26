export const WATCHED_AT_MOST = 50;
const WATCHED = { urls: ["http://*/*", "https://*/*"], types: ["main_frame", "xmlhttprequest", "media", "other"] };
const MANIFEST_PATH = /\.(m3u8|mpd)$/i;
const MANIFEST_TYPE = /mpegurl|dash\+xml/i;
const MEDIA_FILE = /\.(mp4|m4v|mov|webm|mkv|m4a|mp3|aac|ogg|oga|opus|wav|flac)$/i;
const BYTE_RANGE_QUERY = /^(bytestart|byteend|range)$/i;
const FROM_THE_START = /^bytes=0-$/i;
const PENDING_AT_MOST = 500;

function kindOf({ url, contentType, status, range }) {
  let link;
  try {
    link = new URL(url);
  } catch {
    return null;
  }
  if (status < 200 || status > 299) return null;
  if (MANIFEST_PATH.test(link.pathname) || MANIFEST_TYPE.test(contentType ?? "")) return "manifest";
  if (!MEDIA_FILE.test(link.pathname)) return null;
  if (range && !FROM_THE_START.test(range)) return null;
  if ([...link.searchParams.keys()].some((key) => BYTE_RANGE_QUERY.test(key))) return null;
  return "file";
}

function header(headers, name) {
  return headers?.find((entry) => entry.name.toLowerCase() === name)?.value;
}

export function startWatching({ chrome }) {
  const tabs = new Map();
  const sent = new Map();

  chrome.webRequest?.onSendHeaders.addListener(
    (details) => {
      if (details.tabId < 0) return;
      const headers = details.requestHeaders ?? [];
      if (sent.size >= PENDING_AT_MOST) sent.delete(sent.keys().next().value);
      sent.set(details.requestId, { referrer: header(headers, "referer"), range: header(headers, "range") });
    },
    WATCHED,
    ["requestHeaders", "extraHeaders"],
  );

  chrome.webRequest?.onHeadersReceived.addListener(
    (details) => {
      const request = sent.get(details.requestId) ?? {};
      sent.delete(details.requestId);
      if (details.tabId < 0) return;
      const contentType = header(details.responseHeaders, "content-type");
      if (details.type === "main_frame") {
        if (details.statusCode >= 200 && details.statusCode <= 299 && /text\/html|xhtml/i.test(contentType ?? "")) tabs.delete(details.tabId);
        return;
      }
      const kind = kindOf({ url: details.url, contentType, status: details.statusCode, range: request.range });
      if (!kind) return;
      const list = (tabs.get(details.tabId) ?? []).filter((entry) => entry.url !== details.url);
      const entry = { url: details.url, kind };
      if (contentType) entry.contentType = contentType;
      if (request.referrer) entry.referrer = request.referrer;
      list.push(entry);
      tabs.set(details.tabId, list.slice(-WATCHED_AT_MOST));
    },
    WATCHED,
    ["responseHeaders"],
  );

  chrome.webRequest?.onErrorOccurred?.addListener((details) => sent.delete(details.requestId), WATCHED);
  chrome.tabs?.onRemoved?.addListener((tabId) => tabs.delete(tabId));

  return {
    requestsFor(tabId) {
      return [...(tabs.get(tabId) ?? [])];
    },
    pendingRequests() {
      return sent.size;
    },
  };
}
