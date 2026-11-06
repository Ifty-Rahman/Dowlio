export function scanPage(doc = document, base = doc.baseURI) {
  const VIDEO_FILES = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "3gp", "3g2", "ogv", "divx", "vob", "m2ts", "mts", "rmvb"];
  const AUDIO_FILES = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "flac", "aiff", "aif", "wma", "mka", "ape", "alac", "ac3", "dts", "wv"];
  const EMBEDDED_LIMIT = 160000;
  const MEDIA_KEYS = ["reblogKey", "grid_title", "upNextThumbnailUrl", "carousel_media", "video_versions", "video_dash_manifest", "videoDeliveryResponseFragment", "playable_url", "browser_native_hd_url"];
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

  const LABEL_WORDS = 8;
  const LABEL_LENGTH = 60;
  const POSTS = 'article, [role="article"], li, figure';
  const POST_TEXT = '[data-testid="tweetText"], [data-testid="post-content"], [slot="text-body"], [itemprop="articleBody"], [itemprop="description"]';
  const AUTHORS = '[data-testid="User-Name"] span, [rel="author"], [itemprop="author"], [data-testid="post_author"]';
  const IGNORED = "video, audio, button, time, script, style, noscript, [aria-hidden=\"true\"]";
  const described = [];
  const elements = everywhere("video, audio");

  function squash(text) {
    return (text || "").replace(/\s+/g, " ").trim();
  }

  function shorten(text) {
    return text.length > LABEL_LENGTH ? text.slice(0, LABEL_LENGTH - 1).trimEnd() + "…" : text;
  }

  function parentOf(element) {
    if (element.parentElement) return element.parentElement;
    const root = element.getRootNode?.();
    return root && root.host ? root.host : null;
  }

  function ancestors(element) {
    const found = [];
    for (let next = parentOf(element); next && next.tagName && next.tagName.toLowerCase() !== "html"; next = parentOf(next)) {
      found.push(next);
      if (next.tagName.toLowerCase() === "body") break;
    }
    return found;
  }

  function ownText(box) {
    const copy = box.cloneNode(true);
    copy.querySelectorAll(IGNORED).forEach((element) => element.remove());
    return squash(copy.textContent);
  }

  function holdsOnlyThis(box) {
    return box.tagName.toLowerCase() !== "body" && box.querySelectorAll("video, audio").length === 1;
  }

  function post(element) {
    const chain = ancestors(element);
    const marked = chain.find((box) => box.matches?.(POSTS) && box.tagName.toLowerCase() !== "body");
    if (marked) return marked;
    return chain.find((box) => holdsOnlyThis(box) && ownText(box).split(" ").length >= 2);
  }

  function postLabel(box) {
    if (!box) return null;
    const text = squash(box.querySelector(POST_TEXT)?.textContent) || ownText(box);
    if (!text) return null;
    const author = squash(box.querySelector(AUTHORS)?.textContent);
    const start = text.split(" ").slice(0, LABEL_WORDS).join(" ");
    return author && !start.startsWith(author) ? `${author}: ${start}` : start;
  }

  function titleLabel() {
    const title = squash(doc.querySelector("title")?.textContent);
    if (!title) return null;
    const site = squash(doc.querySelector('meta[property="og:site_name"]')?.getAttribute("content")).toLowerCase();
    const host = (new URL(base).hostname.split(".").slice(-2, -1)[0] || "").toLowerCase();
    const parts = title.split(/\s+[|\-–—·•]\s+/);
    const kept = parts.filter((part) => {
      const lowered = part.toLowerCase();
      return lowered !== site && !(host && lowered.replace(/\s+/g, "").includes(host));
    });
    return kept.length ? kept.join(" - ") : title;
  }

  const GENERIC = /^(video|audio|media)?\s*(player|video|audio)?$|^advertisement$|^ad$/i;

  function named(text) {
    return text && !GENERIC.test(text) ? text : "";
  }

  function headingLabel(element, box) {
    const own = named(squash(element.getAttribute("aria-label") || element.getAttribute("title")));
    if (own) return own;
    for (const scope of [box, ...ancestors(element)].filter(Boolean)) {
      const label = named(squash(scope.getAttribute?.("aria-label")));
      if (label && scope.tagName.toLowerCase() !== "body") return label;
      const heading = squash(scope.querySelector?.("h1, h2, h3, h4, h5, h6")?.textContent);
      if (heading && holdsOnlyThis(scope)) return heading;
    }
    return null;
  }

  function visibleShare(element) {
    const box = element.getBoundingClientRect?.();
    const view = doc.defaultView;
    const width = view?.innerWidth || 0;
    const height = view?.innerHeight || 0;
    if (!box || !box.width || !box.height || !width || !height) return 0;
    const across = Math.max(0, Math.min(box.right, width) - Math.max(box.left, 0));
    const down = Math.max(0, Math.min(box.bottom, height) - Math.max(box.top, 0));
    return Math.round(((across * down) / (box.width * box.height)) * 100) / 100;
  }

  function frameOrigin() {
    const own = doc.defaultView?.origin;
    if (typeof own === "string" && /^https?:/.test(own)) return own;
    try {
      const url = new URL(base);
      return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
    } catch {
      return null;
    }
  }

  const origin = frameOrigin();

  const isPlaying = (element) => element.paused === false && !element.ended;
  const watchedNow = elements.filter((element) => isPlaying(element) && visibleShare(element) > 0);

  function describe(element, index) {
    const box = post(element);
    const alone = elements.length === 1 || (watchedNow.length === 1 && watchedNow[0] === element);
    const label = postLabel(box) || (alone ? titleLabel() : null) || headingLabel(element, box) || `Video ${index + 1} of ${elements.length}`;
    const entry = { group: index + 1, label: shorten(label), playing: element.paused === false && !element.ended, visible: visibleShare(element) };
    const poster = resolve(element.getAttribute("poster"));
    if (poster) entry.poster = poster;
    if (Number.isFinite(element.duration) && element.duration > 0) entry.duration = element.duration;
    if (origin) entry.origin = origin;
    return entry;
  }

  elements.forEach((element, index) => described.push(describe(element, index)));

  for (const element of elements) {
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

  function mediaHolders(value, found = []) {
    if (Array.isArray(value)) {
      value.forEach((child) => mediaHolders(child, found));
    } else if (value && typeof value === "object") {
      if (MEDIA_KEYS.some((key) => key in value)) found.push(value);
      else Object.values(value).forEach((child) => mediaHolders(child, found));
    }
    return found;
  }

  const embeddedJson = [];
  const holderAt = new Map();
  const wholeBlobs = [];
  const bytes = (text) => new TextEncoder().encode(text).length;
  let embeddedBytes = 0;
  function keep(text) {
    const size = bytes(text);
    if (embeddedBytes + size > EMBEDDED_LIMIT) return;
    embeddedBytes += size;
    embeddedJson.push(text);
  }
  for (const script of doc.querySelectorAll('script[type="application/json"]')) {
    const text = script.textContent;
    if (!/video|audio|playable|dash|m3u8|\.mp4/i.test(text)) continue;
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      continue;
    }
    const holders = mediaHolders(parsed);
    if (!holders.length) {
      wholeBlobs.push(text);
      continue;
    }
    for (const holder of holders) {
      const holderText = JSON.stringify(holder);
      const id = String(holder.id ?? holder.pk ?? holder.code ?? holderText);
      const index = holderAt.get(id);
      if (index === undefined) {
        holderAt.set(id, embeddedJson.length);
        embeddedJson.push(holderText);
      } else if (holderText.length > embeddedJson[index].length) {
        embeddedJson[index] = holderText;
      }
    }
  }
  const holderTexts = embeddedJson.splice(0);
  for (const text of holderTexts.concat(wholeBlobs)) keep(text);

  const title = (doc.querySelector("title")?.textContent || "").trim();
  return { title, media, players: described, embeddedJson };
}
