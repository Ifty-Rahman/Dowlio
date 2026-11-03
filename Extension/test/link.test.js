import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function boot(options = {}) {
  const chrome = fakeChrome(options);
  const timers = new FakeTimers();
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator: navigatorLike() });
  await flush();
  return { chrome, timers, net };
}

test("tries Dowlio's ports in order, then waits 5 seconds and starts again", async () => {
  const { timers, net } = await boot();

  for (const port of [51517, 51518, 51519, 51520]) {
    assert.equal(net.last().url, `ws://127.0.0.1:${port}`);
    await net.last().fail();
  }
  assert.equal(net.sockets.length, 4);
  await timers.advance(4999);
  assert.equal(net.sockets.length, 4);
  await timers.advance(1);
  assert.equal(net.last().url, "ws://127.0.0.1:51517");
});

test("an unpaired browser asks to pair and waits for the code Dowlio shows", async () => {
  const { chrome, net } = await boot();

  await net.last().accept();
  await net.last().reply({ type: "pair.codeNeeded" });

  const request = net.last().sent[0];
  assert.equal(request.type, "pair.request");
  assert.equal(request.v, 1);
  assert.equal(request.code, undefined);
  assert.equal(request.browser, "Arc");
  assert.equal(request.version, "0.2.0");
  assert.equal(request.extensionId, "abcdefghijklmnopabcdefghijklmnop");
  assert.equal(chrome.storage.local.data.status, "pairing");
});

test("the code typed in the popup goes to Dowlio, and an approval keeps the token and proves Dowlio before connecting", async () => {
  const { chrome, net } = await boot();
  await net.last().accept();
  await net.last().reply({ type: "pair.codeNeeded" });

  chrome.runtime.sendMessage({ type: "pair.code", code: "482913" });
  await flush();
  await net.last().reply({ type: "pair.approved", token: "tok-123" });
  assert.equal(chrome.storage.local.data.token, "tok-123");
  await net.last().prove("tok-123");

  assert.deepEqual(net.last().sent.find((message) => message.type === "pair.code").code, "482913");
  assert.equal(net.last().sent.some((message) => JSON.stringify(message).includes("tok-123")), false);
  assert.equal(chrome.storage.local.data.status, "connected");
  assert.equal(chrome.badge.text, "");
});

test("a wrong code is shown in the popup with the tries left", async () => {
  const { chrome, net } = await boot();
  await net.last().accept();
  chrome.runtime.sendMessage({ type: "pair.code", code: "111111" });
  await flush();

  await net.last().reply({ type: "pair.codeWrong", left: 2 });

  assert.deepEqual(chrome.storage.local.data.pairingError, { left: 2 });
});

test("an approval nobody typed a code for is ignored", async () => {
  const { chrome, net } = await boot();
  await net.last().accept();

  await net.last().reply({ type: "pair.approved", token: "planted" });

  assert.equal(chrome.storage.local.data.token, undefined);
});

test("a paired browser says hello with a key and a fresh nonce, never its token", async () => {
  const { net } = await boot({ stored: { token: "tok-123" } });

  await net.last().accept();
  const hello = await net.last().sentMessage("hello");

  assert.equal(hello.token, undefined);
  assert.equal(typeof hello.key, "string");
  assert.ok(hello.nonce.length >= 16);
  assert.equal(JSON.stringify(hello).includes("tok-123"), false);
});

test("a server that can't prove it's Dowlio is dropped and gets nothing", async () => {
  const { chrome, net } = await boot({ stored: { token: "tok" } });
  chrome.cookies.jar["https://mail.example"] = [{ name: "session", value: "secret", domain: "mail.example" }];
  const socket = net.last();
  await socket.accept();

  await socket.prove("tok", { proof: "not-the-right-proof-at-all" });
  for (const deadline = Date.now() + 2000; Date.now() < deadline && socket.readyState !== 3; ) await new Promise((resolve) => setTimeout(resolve, 1));
  await socket.reply({ type: "hello.ok" });
  await socket.reply({ type: "site.signIn", requestId: "s1", url: "https://mail.example/" });

  assert.notEqual(chrome.storage.local.data.status, "connected");
  assert.equal(socket.sent.some((message) => message.type === "site.signIn" || message.type === "hello.proof"), false);
  assert.equal(socket.readyState, 3);
});

test("an unproven server asking for cookies, scans or downloads gets nothing", async () => {
  const { chrome, net } = await boot({ stored: { token: "tok" } });
  chrome.cookies.jar["https://mail.example"] = [{ name: "session", value: "secret", domain: "mail.example" }];
  const socket = net.last();
  await socket.accept();

  await socket.reply({ type: "hello.ok" });
  await socket.reply({ type: "site.signIn", requestId: "s1", url: "https://mail.example/" });
  await socket.reply({ type: "page.scan", requestId: "p1" });
  await socket.reply({ type: "browser.download", url: "https://evil.example/a.exe" });
  await socket.reply({ type: "settings.update", catches: false, neverCatch: [] });

  assert.deepEqual(socket.sent.map((message) => message.type), ["hello"]);
  assert.deepEqual(chrome.downloads.calls, []);
  assert.equal(chrome.storage.local.data.catching, undefined);
});

test("a rejected key keeps the token and asks Dowlio to pair again", async () => {
  const { chrome, net } = await boot({ stored: { token: "old" } });
  await net.last().accept();

  await net.last().reply({ type: "hello.rejected" });
  await net.last().fail();
  await net.last().accept();

  assert.equal(chrome.storage.local.data.token, "old");
  assert.equal(net.sockets.length, 2);
  assert.equal(net.last().sent[0].type, "pair.request");
});

test("pings every 20 seconds once connected", async () => {
  const { timers, net } = await boot({ stored: { token: "tok" } });
  await net.last().accept();
  await net.last().prove();

  await timers.advance(60000);

  assert.deepEqual(net.last().sent.map((message) => message.type), ["hello", "hello.proof", "ping", "ping", "ping"]);
});

test("keeps pinging while a pairing request waits for the user, so the browser doesn't stop the worker", async () => {
  const { timers, net } = await boot();
  await net.last().accept();

  await timers.advance(40000);

  assert.deepEqual(net.last().sent.map((message) => message.type), ["pair.request", "ping", "ping"]);
});

test("an alarm every 30 seconds wakes the worker to reconnect while Dowlio is away", async () => {
  const { chrome, timers, net } = await boot();
  for (let attempt = 0; attempt < 4; attempt += 1) await net.last().fail();
  assert.deepEqual(chrome.alarms.created["dowlio-connect"], { periodInMinutes: 0.5 });

  chrome.alarms.fire("dowlio-connect");
  await flush();
  assert.equal(net.sockets.length, 5);
  assert.equal(net.last().url, "ws://127.0.0.1:51517");
  await timers.advance(5000);
  assert.equal(net.sockets.length, 5);

  await net.last().accept();
  chrome.alarms.fire("dowlio-connect");
  await flush();
  assert.equal(net.sockets.length, 5);
});

test("a dropped link greys the badge and reconnects after 5 seconds", async () => {
  const { chrome, timers, net } = await boot({ stored: { token: "tok" } });
  await net.last().accept();
  await net.last().prove();

  await net.last().fail();
  assert.equal(chrome.storage.local.data.status, "disconnected");
  assert.equal(chrome.badge.text, "off");
  assert.equal(chrome.badge.color, "#8E8E93");
  await timers.advance(5000);

  assert.equal(net.sockets.length, 2);
  assert.equal(net.last().url, "ws://127.0.0.1:51517");
});

test("a denied pairing waits until the user asks again from the popup", async () => {
  const { chrome, timers, net } = await boot();
  await net.last().accept();

  const pairRequests = () => net.last().sent.filter((message) => message.type === "pair.request");

  await net.last().reply({ type: "pair.refused", reason: "denied" });
  assert.equal(chrome.storage.local.data.status, "denied");
  await timers.advance(60000);
  assert.equal(pairRequests().length, 1);

  chrome.runtime.sendMessage({ type: "pair.retry" });
  await flush();

  assert.equal(pairRequests().length, 2);
  assert.equal(chrome.storage.local.data.status, "pairing");
});

test("a busy or rate-limited pairing asks again after 5 seconds", async () => {
  const { timers, net } = await boot();
  await net.last().accept();

  await net.last().reply({ type: "pair.refused", reason: "busy" });
  await timers.advance(5000);

  assert.equal(net.last().sent.length, 2);
  assert.equal(net.last().sent[1].type, "pair.request");
});

test("answers Dowlio's ping with a pong, so Test in Dowlio can pass", async () => {
  const { net } = await boot({ stored: { token: "tok" } });
  await net.last().accept();
  await net.last().prove();

  await net.last().reply({ type: "ping", requestId: "test-1" });

  assert.deepEqual(net.last().sent.filter((message) => message.type === "pong"), [{ v: 1, type: "pong", requestId: "test-1" }]);
});

test("reloads itself when Dowlio says a newer Dowlio Connect is on disk", async () => {
  const { chrome, net } = await boot({ stored: { token: "tok" } });
  await net.last().accept();
  await net.last().prove();

  await net.last().reply({ type: "extension.reload" });

  assert.equal(chrome.runtime.reloads, 1);
});

test("connects when the browser starts it again after a reload or update", async () => {
  const { chrome, net } = await boot({ stored: { token: "tok" } });
  for (let port = 0; port < 4; port += 1) await net.last().fail();
  const before = net.sockets.length;

  chrome.runtime.installedListeners.forEach((listener) => listener({ reason: "update" }));
  await flush();

  assert.equal(net.sockets.length, before + 1);
});
