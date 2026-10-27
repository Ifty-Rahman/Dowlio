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
  chrome.windows.list = [{ id: 1, type: "normal", focused: true, tabs: [{ id: 6, active: false, url: "https://www.example.com/" }, { id: 7, active: true, url: "https://www.example.com/watch?v=1", title: "Holiday clip - Example" }] }];
  chrome.cookies.jar["https://www.example.com"] = [{ name: "session", value: "abc" }];
  chrome.scripting.frames = [{ frameId: 0, result: { title: "Holiday clip", media: [{ url: "https://cdn.example.com/clip.mp4", kind: "video" }], embeddedJson: [] } }];

  await socket.reply({ type: "page.scan", requestId: "scan-1" });
  await settle();

  assert.deepEqual(chrome.scripting.calls.filter((call) => call.target.allFrames).map((call) => call.target), [{ tabId: 7, allFrames: true }]);
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
  for (const tab of [null, { id: 3, active: true, url: "chrome://extensions/" }, { id: 4, active: true }]) {
    const { chrome, socket } = await worker();
    chrome.windows.list = [{ id: 1, type: "normal", focused: true, tabs: tab ? [tab] : [] }];

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

test("a browser that can't list its windows answers that there's no page", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.getAll = () => {
    throw new Error("No window");
  };

  await socket.reply({ type: "page.scan", requestId: "scan-4" });
  await settle();

  assert.deepEqual(replies(socket, "page.none").map(({ reason }) => reason), ["noTab"]);
});

test("the focused browser window is scanned, not a small window that was focused last", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    { id: 1, type: "normal", focused: true, tabs: [{ id: 7, active: true, url: "https://www.example.com/watch?v=1" }] },
    { id: 2, type: "popup", focused: false, tabs: [{ id: 9, active: true, url: "https://x.example.com/photo/1" }] },
  ];
  chrome.windows.lastFocused = 2;

  await socket.reply({ type: "page.scan", requestId: "scan-5" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://www.example.com/watch?v=1"]);
});

test("with no browser window focused, the last focused browser window is scanned", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    { id: 1, type: "normal", focused: false, tabs: [{ id: 7, active: true, url: "https://www.example.com/a" }] },
    { id: 3, type: "normal", focused: false, tabs: [{ id: 8, active: true, url: "https://www.example.com/b" }] },
    { id: 2, type: "popup", focused: false, tabs: [{ id: 9, active: true, url: "https://x.example.com/photo/1" }] },
  ];
  chrome.windows.lastFocused = 3;

  await socket.reply({ type: "page.scan", requestId: "scan-6" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://www.example.com/b"]);
});

test("a small focused window, like the one Dia opens links in, is scanned", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    { id: 1, type: "normal", focused: false, tabs: [{ id: 7, active: true, url: "https://www.example.com/watch?v=1" }] },
    { id: 2, type: "popup", focused: true, tabs: [{ id: 9, active: true, url: "https://vimeo.example.com/76979871" }] },
  ];
  chrome.windows.lastFocused = 1;

  await socket.reply({ type: "page.scan", requestId: "scan-7" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://vimeo.example.com/76979871"]);
});

test("the tab on screen is scanned even while Dia still calls an earlier tab active", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    {
      id: 1, type: "normal", focused: false,
      tabs: [
        { id: 7, active: true, lastAccessed: 1_000, url: "https://www.example.com/first" },
        { id: 8, active: false, lastAccessed: 50_000, url: "https://www.example.com/shown" },
        { id: 9, active: false, lastAccessed: 20_000, url: "https://www.example.com/older" },
      ],
    },
  ];
  chrome.windows.lastFocused = 1;
  chrome.scripting.visibility = { 8: "visible" };

  await socket.reply({ type: "page.scan", requestId: "scan-8" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://www.example.com/shown"]);
});

test("the active tab is scanned when it's the one on screen, even if another was used later", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    {
      id: 1, type: "normal", focused: true,
      tabs: [
        { id: 7, active: true, lastAccessed: 50_000, url: "https://www.example.com/active" },
        { id: 8, active: false, lastAccessed: 50_400, url: "https://www.example.com/left" },
      ],
    },
  ];
  chrome.scripting.visibility = { 7: "visible" };

  await socket.reply({ type: "page.scan", requestId: "scan-9" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://www.example.com/active"]);
});

test("when no tab says it's on screen, the active tab is scanned", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    {
      id: 1, type: "normal", focused: true,
      tabs: [
        { id: 7, active: true, lastAccessed: 1_000, url: "https://www.example.com/active" },
        { id: 8, active: false, lastAccessed: 50_000, url: "https://www.example.com/later" },
      ],
    },
  ];

  await socket.reply({ type: "page.scan", requestId: "scan-10" });
  await settle();

  assert.deepEqual(replies(socket, "page.send").map(({ url }) => url), ["https://www.example.com/active"]);
});

test("a new tab page in front answers that there's no page, even with web pages behind it", async () => {
  const { chrome, socket } = await worker();
  chrome.windows.list = [
    {
      id: 1, type: "normal", focused: true,
      tabs: [
        { id: 7, active: true, lastAccessed: 60_000, url: "chrome://newtab/" },
        { id: 8, active: false, lastAccessed: 50_000, url: "https://www.example.com/behind" },
      ],
    },
  ];

  await socket.reply({ type: "page.scan", requestId: "scan-11" });
  await settle();

  assert.deepEqual(replies(socket, "page.send"), []);
  assert.deepEqual(replies(socket, "page.none").map(({ reason }) => reason), ["noTab"]);
});
