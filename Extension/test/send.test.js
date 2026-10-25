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

const menuClick = { menuItemId: "send-to-dowlio", linkUrl: "https://cdn.example.com/files/Report.pdf", pageUrl: "https://example.com/reports" };
const sends = (socket) => socket.sent.filter((message) => message.type === "link.send");

test("Send to Dowlio appears only on links", async () => {
  const { chrome } = await worker();

  assert.deepEqual(chrome.contextMenus.items, [{ id: "send-to-dowlio", title: "Send to Dowlio", contexts: ["link"] }]);
});

test("choosing Send to Dowlio hands the link and its page to Dowlio", async () => {
  const { chrome, socket } = await worker();

  await chrome.contextMenus.click(menuClick, { id: 3, url: "https://example.com/reports" });

  const [sent] = sends(socket);
  assert.equal(sent.url, "https://cdn.example.com/files/Report.pdf");
  assert.equal(sent.referrer, "https://example.com/reports");
  assert.equal(sent.browser, "Arc");
  assert.equal(sent.userAgent, "Mozilla/5.0 Arc");
  assert.deepEqual(chrome.downloads.calls, []);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("with Dowlio not running, the menu says to open Dowlio and the browser downloads nothing", async () => {
  const { chrome, net } = await worker({ connect: false });

  await chrome.contextMenus.click(menuClick, { id: 3 });

  assert.equal(net.last().sent.filter((message) => message.type === "link.send").length, 0);
  assert.deepEqual(chrome.downloads.calls, []);
  assert.equal(chrome.notifications.shown.length, 1);
  assert.equal(chrome.notifications.shown[0].message, "Open Dowlio to download with it.");
});

test("a link Dowlio never confirms says Dowlio didn't answer", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(menuClick, { id: 3 });
  await timers.advance(5000);
  await flush();

  assert.equal(sends(socket).length, 1);
  assert.equal(chrome.notifications.shown.length, 1);
  assert.equal(chrome.notifications.shown[0].title, "Dowlio didn't answer");
});

test("a link Dowlio confirms shows nothing more", async () => {
  const { chrome, socket, timers } = await worker();

  await chrome.contextMenus.click(menuClick, { id: 3 });
  await socket.reply({ type: "link.received", requestId: sends(socket)[0].requestId });
  await timers.advance(5000);
  await flush();

  assert.deepEqual(chrome.notifications.shown, []);
});
