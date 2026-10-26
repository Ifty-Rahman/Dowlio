export function scanPage(doc = document, base = doc.baseURI) {
  const VIDEO_FILES = ["mp4", "m4v", "mov", "webm", "mkv"];
  const AUDIO_FILES = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "flac"];
  const EMBEDDED_LIMIT = 100000;
  const media = [];
  const seen = new Set();
  let players = 0;

  function resolve(value) {
    if (!value) return null;
    try {
      const url = new URL(value, base);
      return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
    } catch {
      return null;
    }
  }

  function fileKind(url) {
    const ext = new URL(url).pathname.split(".").pop().toLowerCase();
    if (VIDEO_FILES.includes(ext)) return "video";
    if (AUDIO_FILES.includes(ext)) return "audio";
    return null;
  }

  function add(value, kind, extra = {}) {
    const url = resolve(value);
    if (!url || seen.has(url)) return;
    seen.add(url);
    const entry = { url, kind };
    const poster = resolve(extra.poster);
    if (poster) entry.poster = poster;
    if (Number.isFinite(extra.duration) && extra.duration > 0) entry.duration = extra.duration;
    if (extra.group) entry.group = extra.group;
    media.push(entry);
  }

  function everywhere(selector, root = doc, found = []) {
    root.querySelectorAll(selector).forEach((element) => found.push(element));
    root.querySelectorAll("*").forEach((element) => {
      if (element.shadowRoot) everywhere(selector, element.shadowRoot, found);
    });
    return found;
  }

  for (const element of everywhere("video, audio")) {
    const kind = element.tagName.toLowerCase();
    players += 1;
    const extra = { poster: element.getAttribute("poster"), duration: element.duration, group: players };
    const own = element.getAttribute("src") || element.currentSrc;
    if (own) add(own, kind, extra);
    for (const source of element.querySelectorAll("source")) {
      const type = (source.getAttribute("type") || "").toLowerCase();
      add(source.getAttribute("src"), type.startsWith("audio/") ? "audio" : type.startsWith("video/") ? "video" : kind, { group: players });
    }
  }

  for (const meta of doc.querySelectorAll("meta")) {
    const key = (meta.getAttribute("property") || meta.getAttribute("name") || "").toLowerCase();
    const content = meta.getAttribute("content");
    if (["og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream"].includes(key)) add(content, "video");
    if (["og:audio", "og:audio:url", "og:audio:secure_url"].includes(key)) add(content, "audio");
  }

  function mediaObjects(value) {
    if (Array.isArray(value)) return value.flatMap(mediaObjects);
    if (!value || typeof value !== "object") return [];
    const own = value["@type"] === "VideoObject" || value["@type"] === "AudioObject" ? [value] : [];
    return own.concat(Object.values(value).flatMap((child) => (child && typeof child === "object" ? mediaObjects(child) : [])));
  }

  for (const script of doc.querySelectorAll('script[type="application/ld+json"]')) {
    let parsed;
    try {
      parsed = JSON.parse(script.textContent);
    } catch {
      continue;
    }
    for (const entry of mediaObjects(parsed)) {
      if (typeof entry.contentUrl === "string") add(entry.contentUrl, entry["@type"] === "AudioObject" ? "audio" : "video");
    }
  }

  for (const anchor of everywhere("a[href]")) {
    const url = resolve(anchor.getAttribute("href"));
    const kind = url && fileKind(url);
    if (kind) add(url, kind);
  }

  const embeddedJson = [];
  let embeddedBytes = 0;
  for (const script of doc.querySelectorAll('script[type="application/json"]')) {
    const text = script.textContent;
    if (!/video|audio|playable|dash|m3u8|\.mp4/i.test(text)) continue;
    if (embeddedBytes + text.length > EMBEDDED_LIMIT) continue;
    embeddedBytes += text.length;
    embeddedJson.push(text);
  }

  const title = (doc.querySelector("title")?.textContent || "").trim();
  return { title, media, embeddedJson };
}
