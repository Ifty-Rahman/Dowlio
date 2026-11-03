import assert from "node:assert/strict";
import { test } from "node:test";
import { startWatching, WATCHED_AT_MOST } from "../lib/watching.js";
import { fakeChrome } from "./fakes.js";

let ids = 0;
function load(chrome, { tabId = 7, url, type = "xmlhttprequest", method = "GET", status = 200, contentType, range, referer = "https://www.example.com/watch", origin }) {
  const requestId = String((ids += 1));
  const requestHeaders = [{ name: "Referer", value: referer }];
  if (origin) requestHeaders.push({ name: "Origin", value: origin });
  if (range) requestHeaders.push({ name: "Range", value: range });
  chrome.webRequest.fire("onSendHeaders", { requestId, tabId, url, type, requestHeaders });
  const responseHeaders = contentType ? [{ name: "Content-Type", value: contentType }] : [];
  chrome.webRequest.fire("onHeadersReceived", { requestId, tabId, url, type, method, statusCode: status, responseHeaders });
}

function watcher() {
  const chrome = fakeChrome({});
  return { chrome, watching: startWatching({ chrome }) };
}

test("playlists, manifests and whole media files are kept with how they were asked for", () => {
  const { chrome, watching } = watcher();

  load(chrome, { url: "https://surrit.example/a/playlist.m3u8", contentType: "application/vnd.apple.mpegurl", origin: "https://www.example.com" });
  load(chrome, { url: "https://video.example.net/played.mp4", type: "media", contentType: "video/mp4", range: "bytes=0-", status: 206 });
  load(chrome, { url: "https://cdn.example.net/v/dash.mpd", contentType: "application/dash+xml" });
  load(chrome, { url: "https://api.example.org/v2/gifs/x/sd.m3u8", contentType: "text/plain" });
  load(chrome, { url: "https://video.example.net/clip.mp4", type: "media", contentType: "video/mp4" });

  assert.deepEqual(watching.requestsFor(7), [
    { url: "https://surrit.example/a/playlist.m3u8", kind: "manifest", contentType: "application/vnd.apple.mpegurl", referrer: "https://www.example.com/watch" },
    { url: "https://video.example.net/played.mp4", kind: "file", contentType: "video/mp4", referrer: "https://www.example.com/watch" },
    { url: "https://cdn.example.net/v/dash.mpd", kind: "manifest", contentType: "application/dash+xml", referrer: "https://www.example.com/watch" },
    { url: "https://api.example.org/v2/gifs/x/sd.m3u8", kind: "manifest", contentType: "text/plain", referrer: "https://www.example.com/watch" },
    { url: "https://video.example.net/clip.mp4", kind: "file", contentType: "video/mp4", referrer: "https://www.example.com/watch" },
  ]);
});

test("a playlist a player fetches as plain text is kept for Dowlio to read", () => {
  const { chrome, watching } = watcher();

  load(chrome, { url: "https://k1.player.example/u/9/playlist.txt", contentType: "text/plain; charset=utf-8", referer: "https://player.example/" });
  load(chrome, { url: "https://player.example/stats", method: "POST", contentType: "text/plain" });
  load(chrome, { url: "https://player.example/notes.txt", type: "other", contentType: "text/plain" });

  assert.deepEqual(watching.requestsFor(7), [
    { url: "https://k1.player.example/u/9/playlist.txt", kind: "manifest", contentType: "text/plain; charset=utf-8", referrer: "https://player.example/" },
  ]);
});

test("segments, byte ranges and content-type-only matches are dropped", () => {
  const { chrome, watching } = watcher();

  load(chrome, { url: "https://video.example.net/seg/0001.m4s", contentType: "video/iso.segment" });
  load(chrome, { url: "https://cdn.example.net/1080p/video0.ts", contentType: "video/mp2t" });
  load(chrome, { url: "https://v.example.it/abc/CMAF_1080.mp4", contentType: "video/mp4", range: "bytes=0-900", status: 206 });
  load(chrome, { url: "https://scontent.example.net/v/clip.mp4?bytestart=0&byteend=1000", contentType: "video/mp4" });
  load(chrome, { url: "https://cdn.example.net/stream?id=9", contentType: "video/mp4" });
  load(chrome, { url: "https://cdn.example.net/1080p/video1.jpeg", contentType: "image/jpeg" });
  load(chrome, { url: "https://video.example.net/later.mp4", contentType: "video/mp4", range: "bytes=1000-", status: 206 });
  load(chrome, { url: "https://video.example.net/gone.m3u8", contentType: "text/html", status: 404 });

  assert.deepEqual(watching.requestsFor(7), []);
});

test("a tab keeps its last 50, newest last, and a repeat moves to the end", () => {
  const { chrome, watching } = watcher();

  for (let index = 0; index < WATCHED_AT_MOST + 5; index += 1) load(chrome, { url: `https://cdn.example.net/${index}.mp4`, contentType: "video/mp4" });
  load(chrome, { url: "https://cdn.example.net/10.mp4", contentType: "video/mp4" });

  const urls = watching.requestsFor(7).map(({ url }) => url);
  assert.equal(urls.length, WATCHED_AT_MOST);
  assert.equal(urls[0], "https://cdn.example.net/5.mp4");
  assert.equal(urls.at(-1), "https://cdn.example.net/10.mp4");
  assert.equal(urls.filter((url) => url.endsWith("/10.mp4")).length, 1);
});

test("tabs are watched apart, and a closed tab forgets its requests", () => {
  const { chrome, watching } = watcher();
  load(chrome, { tabId: 1, url: "https://cdn.example.net/one.mp4", contentType: "video/mp4" });
  load(chrome, { tabId: 2, url: "https://cdn.example.net/two.mp4", contentType: "video/mp4" });

  chrome.tabs.close(1);

  assert.deepEqual(watching.requestsFor(1), []);
  assert.deepEqual(watching.requestsFor(2).map(({ url }) => url), ["https://cdn.example.net/two.mp4"]);
});

test("loading a new page clears the tab, but moving within a page keeps it", () => {
  const { chrome, watching } = watcher();
  load(chrome, { url: "https://video.example.net/old.mp4", contentType: "video/mp4" });

  load(chrome, { url: "https://x.example.com/home/api?cursor=2", type: "xmlhttprequest", contentType: "application/json" });
  assert.equal(watching.requestsFor(7).length, 1);

  load(chrome, { url: "https://www.example.com/next-page", type: "main_frame", contentType: "text/html" });
  assert.deepEqual(watching.requestsFor(7), []);
});

test("a reply that doesn't load a page leaves the tab's requests alone", () => {
  const { chrome, watching } = watcher();
  load(chrome, { url: "https://video.example.net/clip.mp4", contentType: "video/mp4" });

  load(chrome, { url: "https://www.example.com/files/report.pdf", type: "main_frame", contentType: "application/pdf" });
  load(chrome, { url: "https://www.example.com/ping", type: "main_frame", status: 204 });

  assert.equal(watching.requestsFor(7).length, 1);
});

test("never-catch sites are watched like any other", async () => {
  const chrome = fakeChrome({ stored: { catching: { catches: true, neverCatch: ["example.com"] } } });
  const watching = startWatching({ chrome });

  load(chrome, { url: "https://www.example.com/media/clip.mp4", contentType: "video/mp4" });

  assert.equal(watching.requestsFor(7).length, 1);
});

test("a request that fails is forgotten", () => {
  const { chrome, watching } = watcher();
  chrome.webRequest.fire("onSendHeaders", { requestId: "dead", tabId: 7, url: "https://video.example.net/a.mp4", type: "media", requestHeaders: [] });
  chrome.webRequest.fire("onErrorOccurred", { requestId: "dead", tabId: 7, url: "https://video.example.net/a.mp4", type: "media" });

  assert.equal(watching.pendingRequests(), 0);
});

test("requests outside any tab are ignored", () => {
  const { chrome, watching } = watcher();

  load(chrome, { tabId: -1, url: "https://cdn.example.net/worker.mp4", contentType: "video/mp4" });

  assert.deepEqual(watching.requestsFor(-1), []);
});
