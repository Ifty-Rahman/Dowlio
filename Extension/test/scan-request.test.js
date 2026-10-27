import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function worker() {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  const timers = new FakeTimers();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator: { ...navigatorLike(), userAgent: "Mozilla/5.0 Arc" } });
  await flush();
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  return { chrome, socket: net.last() };
}

const settle = async () => {
  for (let turn = 0; turn < 5; turn += 1) await flush();
};
const replies = (socket, type) => socket.sent.filter((message) => message.type === type);

test("Dowlio asking for a scan sends the active tab of the focused window, under Dowlio's request ID", async () => {
  const { chrome, socket } = await worker();
  chrome.tabs.active = { id: 7, url: "https://www.example.com/watch?v=1", title: "Holiday clip - Example" };
  chrome.cookies.jar["https://www.example.com"] = [{ name: "session", value: "abc" }];
  chrome.scripting.frames = [{ frameId: 0, result: { title: "Holiday clip", media: [{ url: "https://cdn.example.com/clip.mp4", kind: "video" }], embeddedJson: [] } }];

  await socket.reply({ type: "page.scan", requestId: "scan-1" });
  await settle();

  assert.deepEqual(chrome.tabs.queries, [{ active: true, lastFocusedWindow: true }]);
  assert.deepEqual(chrome.scripting.calls.map((call) => call.target), [{ tabId: 7, allFrames: true }]);
  const [sent] = replies(socket, "page.send");
  assert.equal(sent.requestId, "scan-1");
  assert.equal(sent.url, "https://www.example.com/watch?v=1");
  assert.equal(sent.title, "Holiday clip - Example");
  assert.equal(sent.browser, "Arc");
  assert.equal(sent.userAgent, "Mozilla/5.0 Arc");
  assert.deepEqual(sent.cookies, [{ name: "session", value: "abc" }]);
  assert.deepEqual(sent.media, [{ url: "https://cdn.example.com/clip.mp4", kind: "video" }]);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("Dowlio asking for a scan with no web page in front gets told there's no page, and nothing is scanned", async () => {
  for (const active of [null, { id: 3, url: "chrome://extensions/" }, { id: 4 }]) {
    const { chrome, socket } = await worker();
    chrome.tabs.active = active;

    await socket.reply({ type: "page.scan", requestId: "scan-2" });
    await settle();

    assert.deepEqual(replies(socket, "page.send"), []);
    assert.deepEqual(replies(socket, "page.none").map(({ requestId, reason }) => ({ requestId, reason })), [{ requestId: "scan-2", reason: "noTab" }]);
    assert.deepEqual(chrome.scripting.calls, []);
    assert.deepEqual(chrome.notifications.shown, []);
  }
});

test("Dowlio Connect has no keyboard shortcut of its own", async () => {
  const { readFile } = await import("node:fs/promises");
  const manifest = JSON.parse(await readFile(new URL("../manifest.json", import.meta.url), "utf8"));

  assert.equal(manifest.commands, undefined);
});
