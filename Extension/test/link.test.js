import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function boot(options = {}) {
  const chrome = fakeChrome(options);
  const timers = new FakeTimers();
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator: navigatorLike(), random: () => 0.4821 });
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

test("an unpaired browser asks to pair with a four-digit code the popup can show", async () => {
  const { chrome, net } = await boot();

  await net.last().accept();

  const request = net.last().sent[0];
  assert.equal(request.type, "pair.request");
  assert.equal(request.v, 1);
  assert.equal(request.code, "4821");
  assert.equal(request.browser, "Arc");
  assert.equal(request.version, "0.2.0");
  assert.equal(request.extensionId, "abcdefghijklmnopabcdefghijklmnop");
  assert.equal(chrome.storage.local.data.status, "pairing");
  assert.equal(chrome.storage.local.data.code, "4821");
});

test("an approved pairing keeps the token, says hello and shows connected", async () => {
  const { chrome, net } = await boot();
  await net.last().accept();

  await net.last().reply({ type: "pair.approved", token: "tok-123" });
  assert.equal(chrome.storage.local.data.token, "tok-123");
  assert.deepEqual(
    { type: net.last().sent[1].type, token: net.last().sent[1].token, version: net.last().sent[1].version },
    { type: "hello", token: "tok-123", version: "0.2.0" },
  );
  await net.last().reply({ type: "hello.ok" });

  assert.equal(chrome.storage.local.data.status, "connected");
  assert.equal(chrome.storage.local.data.code, undefined);
  assert.equal(chrome.badge.text, "");
});

test("a paired browser says hello with its token straight away", async () => {
  const { net } = await boot({ stored: { token: "tok-123" } });

  await net.last().accept();

  assert.equal(net.last().sent[0].type, "hello");
  assert.equal(net.last().sent[0].token, "tok-123");
});

test("a rejected token is forgotten and the browser asks to pair again at once", async () => {
  const { chrome, net } = await boot({ stored: { token: "old" } });
  await net.last().accept();

  await net.last().reply({ type: "hello.rejected" });
  await net.last().fail();
  await net.last().accept();

  assert.equal(chrome.storage.local.data.token, undefined);
  assert.equal(net.sockets.length, 2);
  assert.equal(net.last().sent[0].type, "pair.request");
});

test("pings every 20 seconds once connected", async () => {
  const { timers, net } = await boot({ stored: { token: "tok" } });
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });

  await timers.advance(60000);

  assert.deepEqual(net.last().sent.map((message) => message.type), ["hello", "signin.sites", "ping", "ping", "ping"]);
});

test("keeps pinging while a pairing request waits for the user, so the browser doesn't stop the worker", async () => {
  const { timers, net } = await boot();
  await net.last().accept();

  await timers.advance(40000);
  await net.last().reply({ type: "pair.approved", token: "tok" });

  assert.deepEqual(net.last().sent.map((message) => message.type), ["pair.request", "ping", "ping", "hello"]);
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
  await net.last().reply({ type: "hello.ok" });

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
  await net.last().reply({ type: "hello.ok" });

  await net.last().reply({ type: "ping", requestId: "test-1" });

  assert.deepEqual(net.last().sent.filter((message) => message.type === "pong"), [{ v: 1, type: "pong", requestId: "test-1" }]);
});
