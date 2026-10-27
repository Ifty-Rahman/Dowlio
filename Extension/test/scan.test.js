import assert from "node:assert/strict";
import { test } from "node:test";
import { parseHTML } from "linkedom";
import { scanPage } from "../lib/scan.js";

const BASE = "https://www.example.com/watch/1";
const scan = (html) => scanPage(parseHTML(html).document, BASE);

test("video and audio elements give their sources, posters and durations", () => {
  const found = scan(`
    <video src="/media/clip.mp4" poster="/media/poster.jpg"></video>
    <audio><source src="https://cdn.example.com/talk.m4a" type="audio/mp4"></audio>
    <video><source src="/media/clip-720.mp4" type="video/mp4"><source src="/media/clip.webm"></video>`);

  assert.deepEqual(found.media, [
    { url: "https://www.example.com/media/clip.mp4", kind: "video", poster: "https://www.example.com/media/poster.jpg", group: 1 },
    { url: "https://cdn.example.com/talk.m4a", kind: "audio", group: 2 },
    { url: "https://www.example.com/media/clip-720.mp4", kind: "video", group: 3 },
    { url: "https://www.example.com/media/clip.webm", kind: "video", group: 3 },
  ]);
});

test("blob sources are skipped", () => {
  const found = scan(`<video src="blob:https://www.example.com/1234"></video>`);

  assert.deepEqual(found.media, []);
});

test("Open Graph, Twitter and JSON-LD media are read", () => {
  const found = scan(`
    <meta property="og:video" content="https://cdn.example.com/og.mp4">
    <meta property="og:audio" content="https://cdn.example.com/og.mp3">
    <meta name="twitter:player:stream" content="https://cdn.example.com/tw.mp4">
    <script type="application/ld+json">{"@graph":[{"@type":"VideoObject","contentUrl":"https://cdn.example.com/ld.mp4"},
      {"@type":"AudioObject","contentUrl":"https://cdn.example.com/ld.mp3"}]}</script>`);

  assert.deepEqual(found.media.map(({ url, kind }) => [url, kind]), [
    ["https://cdn.example.com/og.mp4", "video"],
    ["https://cdn.example.com/og.mp3", "audio"],
    ["https://cdn.example.com/tw.mp4", "video"],
    ["https://cdn.example.com/ld.mp4", "video"],
    ["https://cdn.example.com/ld.mp3", "audio"],
  ]);
});

test("links to media files count, links to other files don't", () => {
  const found = scan(`<a href="/dload/720.mp4">720p</a><a href="/files/report.pdf">PDF</a><a href="/song.mp3">Song</a>`);

  assert.deepEqual(found.media.map(({ url }) => url), ["https://www.example.com/dload/720.mp4", "https://www.example.com/song.mp3"]);
});

test("videos inside open shadow roots are found", () => {
  const { document } = parseHTML(`<shreddit-player></shreddit-player>`);
  const host = document.querySelector("shreddit-player");
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `<video src="https://v.example.com/abc/CMAF_96.mp4"></video>`;

  assert.deepEqual(scanPage(document, BASE).media.map(({ url }) => url), ["https://v.example.com/abc/CMAF_96.mp4"]);
});

test("a second player with the same sources adds nothing", () => {
  const player = `<video><source src="/mov.mp4" type="video/mp4"><source src="/mov.ogg" type="video/ogg"></video>`;
  const found = scan(player + player);

  assert.deepEqual(found.media.map(({ url, group }) => [url, group]), [
    ["https://www.example.com/mov.mp4", 1],
    ["https://www.example.com/mov.ogg", 1],
  ]);
});

test("the same media is listed once", () => {
  const found = scan(`<video src="/a.mp4"></video><meta property="og:video" content="https://www.example.com/a.mp4"><a href="/a.mp4">a</a>`);

  assert.equal(found.media.length, 1);
});

test("embedded JSON that mentions video is passed on, and nothing else of the page is", () => {
  const found = scan(`
    <title>Holiday clip</title>
    <p>Private page text</p>
    <form><input name="password" value="secret"></form>
    <script type="application/json">{"video_versions":[{"url":"https://cdn.example.com/v.mp4"}]}</script>
    <script type="application/json">{"theme":"dark"}</script>`);

  assert.deepEqual(found.embeddedJson, [`{"video_versions":[{"url":"https://cdn.example.com/v.mp4"}]}`]);
  assert.equal(found.title, "Holiday clip");
  assert.deepEqual(Object.keys(found).sort(), ["embeddedJson", "media", "players", "title"]);
  assert.ok(!JSON.stringify(found).includes("Private page text"));
  assert.ok(!JSON.stringify(found).includes("secret"));
});

test("only the media objects of large embedded JSON are passed on, each once", () => {
  const reel = (caption) => ({ pk: "42", caption: { text: caption }, video_versions: [{ url: "https://cdn.example.com/v.mp4" }] });
  const blob = { data: { page: { padding: "x".repeat(200000), viewer: { name: "Private Person" } }, items: [reel("First"), { media: reel("First") }] } };
  const found = scan(`<script type="application/json">${JSON.stringify(blob)}</script>`);

  assert.deepEqual(found.embeddedJson.map((text) => JSON.parse(text)), [reel("First")]);
  assert.ok(!JSON.stringify(found).includes("Private Person"));
});

test("a carousel post is passed on whole, so its videos keep its caption", () => {
  const post = { code: "Ab1", caption: { text: "Holiday" }, carousel_media: [{ video_versions: [{ url: "https://cdn.example.com/1.mp4" }] }] };
  const found = scan(`<script type="application/json">${JSON.stringify({ data: { post } })}</script>`);

  assert.deepEqual(found.embeddedJson.map((text) => JSON.parse(text)), [post]);
});

test("of two media objects with one ID, the fuller is passed on", () => {
  const preview = { pk: "7", video_versions: [] };
  const full = { pk: "7", caption: { text: "Full" }, video_versions: [{ url: "https://cdn.example.com/v.mp4" }] };
  const found = scan(`<script type="application/json">${JSON.stringify([preview, full])}</script>`);

  assert.deepEqual(found.embeddedJson.map((text) => JSON.parse(text)), [full]);
});

test("media objects are passed on before whole blobs that only mention video", () => {
  const blob = `{"video":"${"x".repeat(159950)}"}`;
  const reel = { pk: "9", video_versions: [{ url: "https://cdn.example.com/v.mp4" }] };
  const found = scan(`<script type="application/json">${blob}</script><script type="application/json">${JSON.stringify(reel)}</script>`);

  assert.deepEqual(found.embeddedJson.map((text) => JSON.parse(text)), [reel]);
});

test("the cap counts the bytes the text takes once sent", () => {
  const wide = `{"video":"${"é".repeat(45000)}"}`;
  const found = scan(`<script type="application/json">${wide}</script><script type="application/json">${wide}</script>`);

  assert.equal(found.embeddedJson.length, 1);
});

test("embedded JSON is capped so the whole scan fits in one message", () => {
  const big = `{"video":"${"x".repeat(90000)}"}`;
  const found = scan(`<script type="application/json">${big}</script><script type="application/json">${big}</script>`);

  assert.equal(found.embeddedJson.length, 1);
});
