export const REMEMBERED_FOR = 60000;
export const REMEMBERED_AT_MOST = 200;
export const MAXIMUM_BODY = 64 * 1024;
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
  for (let start = 0; start < bytes.length; start += 0x8000) text += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  return btoa(text);
}

function isText(bytes) {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

function rawBytes(parts) {
  if (parts.some((part) => !part.bytes)) return null;
  const chunks = parts.map((part) => new Uint8Array(part.bytes));
  const bytes = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

function postedBytes(requestBody, contentType) {
  if (requestBody.raw) return rawBytes(requestBody.raw);
  if (!requestBody.formData) return new Uint8Array();
  const boundary = /boundary=("?)([^";]+)\1/i.exec(contentType ?? "")?.[2];
  const multipart = /^multipart\/form-data/i.test(contentType ?? "") && boundary;
  return new TextEncoder().encode(multipart ? encodeMultipart(requestBody.formData, boundary) : encodeForm(requestBody.formData));
}

function replayableBody(requestBody, contentType) {
  if (!requestBody) return {};
  const bytes = postedBytes(requestBody, contentType);
  if (!bytes || bytes.length > MAXIMUM_BODY || !isText(bytes)) return { unsendable: true };
  return bytes.length ? { body: base64(bytes) } : {};
}

function withoutFragment(url) {
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
      const { body, unsendable } = method === "POST" ? replayableBody(bodies.get(details.requestId)?.requestBody, header("content-type")) : {};
      seen.set(withoutFragment(details.url), {
        at: now(),
        method,
        body,
        unsendable,
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
        const entry = url && seen.get(withoutFragment(url));
        if (!entry) continue;
        const request = entry.method === "GET" && entry.headers.length === 0 ? undefined : { method: entry.method, headers: entry.headers };
        if (request && entry.body) request.body = entry.body;
        return { request, referrer: entry.referrer, userAgent: entry.userAgent, unsendable: Boolean(entry.unsendable) };
      }
      return {};
    },
  };
}
