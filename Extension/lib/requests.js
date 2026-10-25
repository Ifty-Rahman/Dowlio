export const REMEMBERED_FOR = 60000;
export const REMEMBERED_AT_MOST = 200;
const WATCHED = { urls: ["http://*/*", "https://*/*"], types: ["main_frame", "sub_frame", "other"] };
const REPLAYED = /^(content-type|origin|x-.+)$/i;

function encodeForm(formData) {
  const pairs = [];
  for (const [name, values] of Object.entries(formData)) {
    for (const value of values) {
      const encode = (text) => encodeURIComponent(text).replace(/%20/g, "+");
      pairs.push(`${encode(name)}=${encode(value)}`);
    }
  }
  return pairs.join("&");
}

function encodeMultipart(formData, boundary) {
  const parts = [];
  for (const [name, values] of Object.entries(formData)) {
    for (const value of values) parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`);
  }
  return `${parts.join("")}--${boundary}--\r\n`;
}

function base64(bytes) {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text);
}

function encodedBody(requestBody, contentType) {
  if (!requestBody) return undefined;
  if (requestBody.raw) {
    const chunks = requestBody.raw.filter((part) => part.bytes).map((part) => new Uint8Array(part.bytes));
    if (chunks.length === 0) return undefined;
    return base64(chunks.flatMap((chunk) => [...chunk]));
  }
  if (!requestBody.formData) return undefined;
  const boundary = /boundary=("?)([^";]+)\1/i.exec(contentType ?? "")?.[2];
  const text = /^multipart\/form-data/i.test(contentType ?? "") && boundary ? encodeMultipart(requestBody.formData, boundary) : encodeForm(requestBody.formData);
  return base64(new TextEncoder().encode(text));
}

function key(url) {
  try {
    const link = new URL(url);
    link.hash = "";
    return link.href;
  } catch {
    return url;
  }
}

export function startWatchingRequests({ chrome, now = Date.now }) {
  const bodies = new Map();
  const seen = new Map();

  function forget() {
    for (const [url, entry] of seen) {
      if (now() - entry.at > REMEMBERED_FOR || seen.size > REMEMBERED_AT_MOST) seen.delete(url);
    }
    for (const [requestId, entry] of bodies) {
      if (now() - entry.at > REMEMBERED_FOR) bodies.delete(requestId);
    }
  }

  chrome.webRequest?.onBeforeRequest.addListener(
    (details) => {
      if (details.method?.toUpperCase() !== "POST" || !details.requestBody) return;
      bodies.set(details.requestId, { requestBody: details.requestBody, at: now() });
    },
    WATCHED,
    ["requestBody"],
  );

  chrome.webRequest?.onSendHeaders.addListener(
    (details) => {
      forget();
      const headers = details.requestHeaders ?? [];
      const header = (name) => headers.find((entry) => entry.name.toLowerCase() === name)?.value;
      const method = details.method?.toUpperCase() ?? "GET";
      const body = method === "POST" ? encodedBody(bodies.get(details.requestId)?.requestBody, header("content-type")) : undefined;
      seen.set(key(details.url), {
        at: now(),
        method,
        body,
        referrer: header("referer"),
        userAgent: header("user-agent"),
        headers: headers
          .filter((entry) => REPLAYED.test(entry.name) && typeof entry.value === "string")
          .map(({ name, value }) => ({ name, value })),
      });
    },
    WATCHED,
    ["requestHeaders", "extraHeaders"],
  );

  return {
    requestFor(...urls) {
      forget();
      for (const url of urls) {
        const entry = url && seen.get(key(url));
        if (!entry) continue;
        const request = entry.method === "GET" && entry.headers.length === 0 ? undefined : { method: entry.method, headers: entry.headers };
        if (request && entry.body) request.body = entry.body;
        return { request, referrer: entry.referrer, userAgent: entry.userAgent };
      }
      return {};
    },
  };
}
