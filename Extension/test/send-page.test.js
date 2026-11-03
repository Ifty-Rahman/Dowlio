import assert from "node:assert/strict";
import { test } from "node:test";
import { CONNECT_WAIT, SCAN_TIMEOUT } from "../lib/sending.js";
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
    await net.last().prove();
  }
  return { chrome, net, timers, socket: net.last() };
}

const tab = { id: 7, url: "https://www.example.com/watch?v=1", title: "Holiday clip - Example" };
const pageClick = { menuItemId: "send-page-to-dowlio", pageUrl: tab.url };
const toasts = (chrome) =>
  chrome.scripting.calls.filter((call) => call.func?.name === "showToast").map((call) => ({ tabId: call.target.tabId, title: call.args[0], message: call.args[1] }));
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

test("each frame's players are sent with their Labels, numbered after the frames before them", async () => {
  const { chrome, socket } = await worker();
  const player = (group, label) => ({ group, label, playing: false, visible: 0 });
  chrome.scripting.frames = [
    { frameId: 0, result: { title: "Feed", media: [{ url: "https://cdn.example.com/a.mp4", kind: "video", group: 1 }], players: [player(1, "First"), player(2, "Second")], embeddedJson: [] } },
    { frameId: 4, result: { title: "", media: [], players: [player(1, "Embedded"), player(2, "Video 2 of 2")], embeddedJson: [] } },
  ];

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  const [sent] = sends(socket);
  assert.deepEqual(sent.players.map(({ group, label }) => [group, label]), [[1, "First"], [2, "Second"], [3, "Embedded"], [4, "Video 4 of 4"]]);
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
  const { chrome, net, timers } = await worker({ connect: false });
  chrome.tabs.byId[7] = tab;

  await chrome.contextMenus.click(pageClick, tab);
  chrome.runtime.sendMessage({ type: "page.send", tabId: 7 });
  await settle();
  await timers.advance(CONNECT_WAIT);
  await settle();

  assert.equal(net.last().sent.filter((message) => message.type === "page.send").length, 0);
  assert.deepEqual(chrome.scripting.calls.filter((call) => call.func?.name !== "showToast"), []);
  assert.deepEqual(toasts(chrome), [
    { tabId: 7, title: "Dowlio isn't running", message: "Open Dowlio to send this page." },
    { tabId: 7, title: "Dowlio isn't running", message: "Open Dowlio to send this page." },
  ]);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("a page Dowlio never confirms says Dowlio didn't answer", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  await timers.advance(5000);
  await flush();

  assert.equal(sends(socket).length, 1);
  assert.deepEqual(toasts(chrome).map(({ title }) => title), ["Dowlio didn't answer"]);
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

test("a sent page carries the media requests its tab made, and only that tab's", async () => {
  const { chrome, socket } = await worker();
  const fire = (tabId, url) => {
    chrome.webRequest.fire("onSendHeaders", { requestId: url, tabId, url, type: "xmlhttprequest", requestHeaders: [{ name: "Referer", value: tab.url }] });
    chrome.webRequest.fire("onHeadersReceived", { requestId: url, tabId, url, type: "xmlhttprequest", statusCode: 200, responseHeaders: [{ name: "Content-Type", value: "application/vnd.apple.mpegurl" }] });
  };
  fire(7, "https://video.example.net/pl/master.m3u8");
  fire(9, "https://other.example.net/elsewhere.m3u8");

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  assert.deepEqual(sends(socket)[0].requests, [
    { url: "https://video.example.net/pl/master.m3u8", kind: "manifest", contentType: "application/vnd.apple.mpegurl", referrer: tab.url },
  ]);
});

test("a page sent while the extension is still reconnecting waits for Dowlio and is sent", async () => {
  const { chrome, net } = await worker({ connect: false });

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  await net.last().accept();
  await net.last().prove();
  await settle();

  assert.equal(sends(net.last())[0]?.url, tab.url);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("a scan that never finishes still sends the page with the requests its players made", async () => {
  const { chrome, socket, timers } = await worker();
  chrome.scripting.executeScript = () => new Promise(() => {});
  chrome.webRequest.fire("onSendHeaders", { requestId: "p", tabId: 7, url: "https://k.player.example/u/playlist.txt", type: "xmlhttprequest", requestHeaders: [] });
  chrome.webRequest.fire("onHeadersReceived", { requestId: "p", tabId: 7, url: "https://k.player.example/u/playlist.txt", type: "xmlhttprequest", method: "GET", statusCode: 200, responseHeaders: [{ name: "Content-Type", value: "text/plain" }] });

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  assert.equal(sends(socket).length, 0);
  await timers.advance(SCAN_TIMEOUT);
  await settle();

  const [sent] = sends(socket);
  assert.equal(sent?.url, tab.url);
  assert.deepEqual(sent.media, []);
  assert.deepEqual(sent.requests.map(({ url }) => url), ["https://k.player.example/u/playlist.txt"]);
  assert.equal(chrome.storage.local.data.lastSend.step, "sentWithoutScan");
});

test("each send keeps its last step, so a page that never arrives can be traced", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(pageClick, tab);
  await settle();
  assert.equal(chrome.storage.local.data.lastSend.step, "sent");
  assert.equal(chrome.storage.local.data.lastSend.host, "www.example.com");
  await socket.reply({ type: "page.received", requestId: sends(socket)[0].requestId });
  await settle();

  assert.equal(chrome.storage.local.data.lastSend.step, "received");
  await timers.advance(5000);
});

test("a scan that throws at once still sends the page", async () => {
  const { chrome, socket } = await worker();
  chrome.scripting.executeScript = () => {
    throw new Error("Frame with ID 0 is showing error page");
  };

  await chrome.contextMenus.click(pageClick, tab);
  await settle();

  assert.equal(sends(socket)[0]?.url, tab.url);
});
