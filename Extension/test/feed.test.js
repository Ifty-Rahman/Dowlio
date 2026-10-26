import assert from "node:assert/strict";
import { test } from "node:test";
import { parseHTML } from "linkedom";
import { scanPage } from "../lib/scan.js";

const BASE = "https://x.example.com/home";

function page(html, { boxes = [], playing = [] } = {}) {
  const { document, window } = parseHTML(html);
  window.innerWidth = 1000;
  window.innerHeight = 800;
  document.querySelectorAll("video").forEach((video, index) => {
    const [top, height] = boxes[index] ?? [2000 + index * 600, 400];
    video.getBoundingClientRect = () => ({ left: 0, right: 600, top, bottom: top + height, width: 600, height });
    video.paused = !playing.includes(index);
  });
  return scanPage(document, BASE);
}

const tweet = (author, text, poster) => `
  <article data-testid="tweet">
    <div data-testid="User-Name"><span>${author}</span><span>@handle</span></div>
    <div data-testid="tweetText">${text}</div>
    <div><video poster="${poster}" src="blob:https://x.example.com/1"></video><span>0:58</span></div>
  </article>`;

test("each video in a post is labelled with the post's first eight words and its author", () => {
  const found = page(tweet("Ada", "Engines weave algebra like looms weave flowers today and always", "https://pbs.example.com/amplify_video_thumb/111/img/a.jpg"));

  assert.deepEqual(found.players.map((player) => player.label), ["Ada: Engines weave algebra like looms weave flowers today"]);
  assert.equal(found.players[0].poster, "https://pbs.example.com/amplify_video_thumb/111/img/a.jpg");
});

test("a generic post container is found by walking up to an article, list item or figure", () => {
  const found = page(`
    <ul>
      <li><p>First clip from the beach today with friends and family</p><div><div><video></video></div></div></li>
      <li><figure><video></video><figcaption>Second clip of the sunset</figcaption></figure></li>
    </ul>`);

  assert.deepEqual(found.players.map((player) => player.label), [
    "First clip from the beach today with friends",
    "Second clip of the sunset",
  ]);
});

test("a page with one video and no post is labelled with its title without the site's name", () => {
  const found = page(`
    <head><title>Cooking pasta at home | Tube Site</title><meta property="og:site_name" content="Tube Site"></head>
    <body><div><video></video></div></body>`);

  assert.deepEqual(found.players.map((player) => player.label), ["Cooking pasta at home"]);
});

test("without post text or title the nearest heading or label is used, then the video's place", () => {
  const found = page(`
    <section><h3>Highlights</h3><div><video></video></div></section>
    <div><video aria-label="Goal replay"></video></div>
    <div><video></video></div>`);

  assert.deepEqual(found.players.map((player) => player.label), ["Highlights", "Goal replay", "Video 3 of 3"]);
});

test("Labels are cut at 60 characters", () => {
  const found = page(tweet("A very long display name indeed", "Supercalifragilisticexpialidocious antidisestablishmentarianism words keep going on", "https://pbs.example.com/a.jpg"));

  const [label] = found.players.map((player) => player.label);
  assert.ok(label.length <= 60);
  assert.ok(label.endsWith("…"));
});

test("each player says whether it is playing and how much of it is on screen", () => {
  const found = page(
    tweet("One", "first post", "https://pbs.example.com/1.jpg") + tweet("Two", "second post", "https://pbs.example.com/2.jpg") + tweet("Three", "third", "https://pbs.example.com/3.jpg"),
    { boxes: [[-300, 400], [200, 400], [1200, 400]], playing: [1] },
  );

  assert.deepEqual(found.players.map(({ playing, visible }) => [playing, visible]), [[false, 0.25], [true, 1], [false, 0]]);
  assert.deepEqual(found.players.map((player) => player.group), [1, 2, 3]);
});

test("players are reported without any other page text", () => {
  const found = page(`<p>Private note</p>` + tweet("Ada", "hello world", "https://pbs.example.com/1.jpg"));

  assert.deepEqual(Object.keys(found.players[0]).sort(), ["group", "label", "playing", "poster", "visible"]);
  assert.ok(!JSON.stringify(found).includes("Private note"));
  assert.ok(!JSON.stringify(found).includes("@handle"));
});
