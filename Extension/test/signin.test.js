import assert from "node:assert/strict";
import { test } from "node:test";
import { signInControls } from "../lib/popup-text.js";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected({ allowed = [] } = {}) {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  if (allowed.length) {
    chrome.permissions.granted.permissions.add("cookies");
    allowed.forEach((origin) => chrome.permissions.granted.origins.add(`${origin}/*`));
  }
  chrome.cookies.jar["https://example.com"] = [{ name: "session", value: "abc", domain: "example.com" }];
  chrome.cookies.jar["https://other.org"] = [{ name: "id", value: "zzz", domain: "other.org" }];
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  return { chrome, socket: net.last() };
}

const sent = (socket, type) => socket.sent.filter((message) => message.type === type);

function download(url) {
  return { id: 7, url, finalUrl: url, referrer: "", filename: "/Users/me/Downloads/a.pdf", mime: "application/pdf", incognito: false, state: "in_progress" };
}

test("a catch from an allowed site carries that site's cookies, and only those", async () => {
  const { chrome, socket } = await connected({ allowed: ["https://example.com"] });

  await chrome.downloads.create(download("https://example.com/private/a.pdf"));
  await chrome.downloads.create({ ...download("https://other.org/b.pdf"), id: 8 });

  const [allowed, other] = sent(socket, "catch.offer");
  assert.deepEqual(allowed.cookies, [{ name: "session", value: "abc" }]);
  assert.equal(other.cookies, undefined);
});

test("a sent link from an allowed site carries its cookies", async () => {
  const { chrome, socket } = await connected({ allowed: ["https://example.com"] });

  await chrome.contextMenus.click({ menuItemId: "send-to-dowlio", linkUrl: "https://example.com/private/a.pdf", pageUrl: "https://example.com/" }, { id: 1 });

  assert.deepEqual(sent(socket, "link.send")[0].cookies, [{ name: "session", value: "abc" }]);
});

test("a catch Dowlio declines for sign-in resumes in the browser and says how to share it", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download("https://example.com/private/a.pdf"));

  await socket.reply({ type: "catch.declined", reason: "needsSignIn", requestId: sent(socket, "catch.offer")[0].requestId });
  await flush();

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["resume", 7]]);
  assert.equal(chrome.notifications.shown[0].message, "example.com needs your sign-in. Click the Dowlio button to let it use your sign-in for this site.");
});

test("Dowlio asking for sign-in on a sent link shows the same note and downloads nothing", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "signin.needed", url: "https://example.com/private/a.pdf" });

  assert.equal(chrome.notifications.shown[0].message, "example.com needs your sign-in. Click the Dowlio button to let it use your sign-in for this site.");
  assert.deepEqual(chrome.downloads.calls, []);
});

test("allowing a site hands its cookies to Dowlio and updates the allowed list", async () => {
  const { chrome, socket } = await connected();

  await chrome.permissions.allow({ permissions: ["cookies"], origins: ["https://example.com/*"] });

  assert.deepEqual(sent(socket, "signin.granted"), [
    { v: 1, type: "signin.granted", requestId: sent(socket, "signin.granted")[0].requestId, origin: "https://example.com", cookies: [{ name: "session", value: "abc" }] },
  ]);
  assert.deepEqual(sent(socket, "signin.sites").at(-1).origins, ["https://example.com"]);
});

test("Dowlio learns the allowed sites when it connects", async () => {
  const { socket } = await connected({ allowed: ["https://example.com", "https://other.org"] });

  assert.deepEqual(sent(socket, "signin.sites").at(-1).origins, ["https://example.com", "https://other.org"]);
});

test("Remove in Dowlio takes the site's permission back, and the last one takes cookies too", async () => {
  const { chrome, socket } = await connected({ allowed: ["https://example.com"] });

  await socket.reply({ type: "signin.revoke", origin: "https://example.com" });
  await flush();

  assert.equal(chrome.permissions.granted.origins.size, 0);
  assert.equal(chrome.permissions.granted.permissions.has("cookies"), false);
  assert.deepEqual(sent(socket, "signin.sites").at(-1).origins, []);
});

test("sign-in sharing is asked for by site, whatever port the page uses", () => {
  assert.equal(signInControls({ tabUrl: "http://127.0.0.1:8765/files", allowedOrigins: [] }).origin, "http://127.0.0.1");
  assert.equal(signInControls({ tabUrl: "http://127.0.0.1:8765/", allowedOrigins: ["http://127.0.0.1"] }).allowed, true);
});

test("Remove in the popup takes the site back the same way", async () => {
  const { chrome, socket } = await connected({ allowed: ["https://example.com", "https://other.org"] });

  chrome.runtime.sendMessage({ type: "signin.remove", origin: "https://example.com" });
  for (let turn = 0; turn < 3; turn += 1) await flush();

  assert.deepEqual([...chrome.permissions.granted.origins], ["https://other.org/*"]);
  assert.equal(chrome.permissions.granted.permissions.has("cookies"), true);
  assert.deepEqual(sent(socket, "signin.sites").at(-1).origins, ["https://other.org"]);
});

test("the popup offers sign-in sharing for the current site, and lists allowed sites", () => {
  assert.deepEqual(signInControls({ tabUrl: "https://www.example.com/files", allowedOrigins: [] }), {
    origin: "https://www.example.com",
    allowed: false,
    buttonText: "Use my sign-in on www.example.com",
  });
  assert.equal(signInControls({ tabUrl: "https://example.com/", allowedOrigins: ["https://example.com"] }).allowed, true);
  assert.equal(signInControls({ tabUrl: "chrome://extensions", allowedOrigins: [] }).origin, null);
});
