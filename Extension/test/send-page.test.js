import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function worker({ connect = true } = {}) {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  const timers = new FakeTimers();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator: { ...navigatorLike(), userAgent: "Mozilla/5.0 Arc" } });
  await flush();
  if (connect) {
    await net.last().accept();
    await net.last().reply({ type: "hello.ok" });
  }
  return { chrome, net, timers, socket: net.last() };
}

const tab = { id: 7, url: "https://www.example.com/watch?v=1", title: "Holiday clip - Example" };
const pageClick = { menuItemId: "send-page-to-dowlio", pageUrl: tab.url };
const sends = (socket) => socket.sent.filter((message) => message.type === "page.send");
const settle = async () => {
  for (let turn = 0; turn < 5; turn += 1) await flush();
};

test("Send to Dowlio appears on pages as well as links", async () => {
  const { chrome } = await worker();

  assert.deepEqual(chrome.contextMenus.items, [
    { id: "send-to-dowlio", title: "Send to Dowlio", contexts: ["link"] },
    { id: "send-page-to-dowlio", title: "Send to Dowlio", contexts: ["page"] },
  ]);
});

test("sending a page scans every frame and hands Dowlio the page and what was found", async () => {
  const { chrome, socket } = await worker();
  chrome.cookies.jar["https://www.example.com"] = [{ name: "session", value: "abc" }];
  chrome.scripting.frames = [
    { frameId: 0, result: { title: "Holiday clip", media: [{ url: "https://cdn.example.com/clip.mp4", kind: "video", duration: 61 }], embeddedJson: ['{"video":1}'] } },
    { frameId: 3, result: { title: "", media: [{ url: "https://cdn.example.com/clip.mp4", kind: "video" }, { url: "https://player.example.net/embed.mp4", kind: "video" }], embeddedJson: [] } },
  ];

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  assert.deepEqual(chrome.scripting.calls.map((call) => call.target), [{ tabId: 7, allFrames: true }]);
  const [sent] = sends(socket);
  assert.equal(sent.url, "https://www.example.com/watch?v=1");
  assert.equal(sent.title, "Holiday clip - Example");
  assert.equal(sent.browser, "Arc");
  assert.equal(sent.userAgent, "Mozilla/5.0 Arc");
  assert.deepEqual(sent.cookies, [{ name: "session", value: "abc" }]);
  assert.deepEqual(sent.media, [
    { url: "https://cdn.example.com/clip.mp4", kind: "video", duration: 61 },
    { url: "https://player.example.net/embed.mp4", kind: "video" },
  ]);
  assert.deepEqual(sent.embeddedJson, ['{"video":1}']);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("a page that can't be scanned is still sent, with nothing found in it", async () => {
  const { chrome, socket } = await worker();
  chrome.scripting.fails = true;

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  const [sent] = sends(socket);
  assert.equal(sent.url, tab.url);
  assert.deepEqual(sent.media, []);
});

test("the popup's button sends the tab it was opened on", async () => {
  const { chrome, socket } = await worker();
  chrome.tabs.byId[7] = tab;

  chrome.runtime.sendMessage({ type: "page.send", tabId: 7 });
  await settle();

  assert.equal(sends(socket)[0]?.url, tab.url);
});

test("with Dowlio not running, sending a page says to open Dowlio and scans nothing", async () => {
  const { chrome, net } = await worker({ connect: false });
  chrome.tabs.byId[7] = tab;

  await chrome.contextMenus.click(pageClick, tab);
  chrome.runtime.sendMessage({ type: "page.send", tabId: 7 });
  await settle();

  assert.equal(net.last().sent.filter((message) => message.type === "page.send").length, 0);
  assert.deepEqual(chrome.scripting.calls, []);
  assert.equal(chrome.notifications.shown.length, 2);
  assert.equal(chrome.notifications.shown[0].message, "Open Dowlio to send this page.");
});

test("a page Dowlio never confirms says Dowlio didn't answer", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  await timers.advance(5000);
  await flush();

  assert.equal(sends(socket).length, 1);
  assert.equal(chrome.notifications.shown[0]?.title, "Dowlio didn't answer");
});

test("a page Dowlio confirms shows nothing more", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  await socket.reply({ type: "page.received", requestId: sends(socket)[0].requestId });
  await timers.advance(5000);
  await flush();

  assert.deepEqual(chrome.notifications.shown, []);
});

test("players in different frames stay apart", async () => {
  const { chrome, socket } = await worker();
  chrome.scripting.frames = [
    { frameId: 0, result: { title: "", media: [{ url: "https://a.example/1.mp4", kind: "video", group: 1 }], embeddedJson: [] } },
    { frameId: 4, result: { title: "", media: [{ url: "https://b.example/2.mp4", kind: "video", group: 1 }], embeddedJson: [] } },
  ];

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  assert.deepEqual(sends(socket)[0].media.map(({ group }) => group), [1, 2]);
});
