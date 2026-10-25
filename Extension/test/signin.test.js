import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected({ settings } = {}) {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  chrome.cookies.jar["https://example.com"] = [{ name: "session", value: "abc", domain: "example.com" }];
  chrome.cookies.jar["https://files.example.com"] = [{ name: "id", value: "zzz", domain: "example.com" }];
  chrome.cookies.jar["https://other.org"] = [{ name: "id", value: "yyy", domain: "other.org" }];
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  if (settings) await net.last().reply({ type: "settings.update", catches: true, neverCatch: [], ...settings });
  return { chrome, socket: net.last() };
}

const sent = (socket, type) => socket.sent.filter((message) => message.type === type);

function download(url, id = 7) {
  return { id, url, finalUrl: url, referrer: "", filename: "/Users/me/Downloads/a.pdf", mime: "application/pdf", incognito: false, state: "in_progress" };
}

test("a catch carries the cookies for the download's own site without asking", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download("https://example.com/private/a.pdf"));
  await chrome.downloads.create(download("https://other.org/b.pdf", 8));

  const [first, second] = sent(socket, "catch.offer");
  assert.deepEqual(first.cookies, [{ name: "session", value: "abc" }]);
  assert.deepEqual(second.cookies, [{ name: "id", value: "yyy" }]);
});

test("cookies come from the host the file is served from, not the page that linked it", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create({ ...download("https://example.com/get/1"), finalUrl: "https://files.example.com/a.pdf" });

  assert.deepEqual(sent(socket, "catch.offer")[0].cookies, [{ name: "id", value: "zzz" }]);
});

test("a sent link carries its site's cookies", async () => {
  const { chrome, socket } = await connected();

  await chrome.contextMenus.click({ menuItemId: "send-to-dowlio", linkUrl: "https://example.com/private/a.pdf", pageUrl: "https://example.com/" }, { id: 1 });

  assert.deepEqual(sent(socket, "link.send")[0].cookies, [{ name: "session", value: "abc" }]);
});

test("a site the user blocked in Dowlio gets no cookies, and neither do its subdomains", async () => {
  const { chrome, socket } = await connected({ settings: { signIn: true, noSignIn: ["example.com"] } });

  await chrome.downloads.create(download("https://files.example.com/a.pdf"));
  await chrome.downloads.create(download("https://other.org/b.pdf", 8));

  const [blocked, allowed] = sent(socket, "catch.offer");
  assert.equal(blocked.cookies, undefined);
  assert.deepEqual(allowed.cookies, [{ name: "id", value: "yyy" }]);
});

test("with sign-in sharing off in Dowlio, no site gets cookies", async () => {
  const { chrome, socket } = await connected({ settings: { signIn: false, noSignIn: [] } });

  await chrome.downloads.create(download("https://example.com/private/a.pdf"));

  assert.equal(sent(socket, "catch.offer")[0].cookies, undefined);
});

test("a site with no cookies sends none", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download("https://nocookies.net/a.pdf"));

  assert.equal(sent(socket, "catch.offer")[0].cookies, undefined);
});

test("a huge cookie jar is trimmed so the message stays small", async () => {
  const { chrome, socket } = await connected();
  chrome.cookies.jar["https://big.example"] = Array.from({ length: 60 }, (_, index) => ({ name: `c${index}`, value: "x".repeat(3000) }));

  await chrome.downloads.create(download("https://big.example/a.pdf"));

  const cookies = sent(socket, "catch.offer")[0].cookies;
  assert.ok(cookies.length > 0 && cookies.length < 60);
  assert.ok(JSON.stringify(cookies).length < 110000);
});

test("a catch Dowlio declines for sign-in starts again in the browser quietly", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download("https://example.com/private/a.pdf"));

  await socket.reply({ type: "catch.declined", reason: "needsSignIn", requestId: sent(socket, "catch.offer")[0].requestId });
  await flush();

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7], ["download", "https://example.com/private/a.pdf"]]);
  assert.deepEqual(chrome.notifications.shown, []);
});

test("Dowlio Connect never asks the user for a permission to read cookies", async () => {
  const { chrome } = await connected();

  assert.equal(chrome.permissions.granted.origins.size, 0);
  assert.equal(chrome.permissions.requests ?? 0, 0);
});

test("when Dowlio leaves a download in the browser, the extension remembers the site and why", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download("https://example.com/private/a.pdf"));

  await socket.reply({ type: "catch.declined", reason: "needsSignIn", requestId: sent(socket, "catch.offer")[0].requestId });
  await flush();

  const { lastDecline } = await chrome.storage.local.get("lastDecline");
  assert.equal(lastDecline.host, "example.com");
  assert.equal(lastDecline.reason, "needsSignIn");
  assert.equal(lastDecline.hadCookies, true);
});

test("a download Dowlio took leaves no note", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download("https://example.com/private/a.pdf"));

  await socket.reply({ type: "catch.accepted", requestId: sent(socket, "catch.offer")[0].requestId });
  await flush();

  assert.equal((await chrome.storage.local.get("lastDecline")).lastDecline, undefined);
});
