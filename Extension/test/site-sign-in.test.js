import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected() {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  chrome.cookies.jar["https://members.example.com"] = [
    { name: "session", value: "abc", domain: "members.example.com", httpOnly: true },
    { name: "theme", value: "dark", domain: "members.example.com" },
  ];
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: { ...navigatorLike(), userAgent: "Mozilla/5.0 Arc" } });
  await flush();
  await net.last().accept();
  await net.last().prove();
  return { chrome, socket: net.last() };
}

const answers = (socket) => socket.sent.filter((message) => message.type === "site.signIn");

test("asked for a link's sign-in, the worker answers with that site's cookies, HttpOnly ones included, and its user agent", async () => {
  const { socket } = await connected();

  await socket.reply({ type: "site.signIn", requestId: "signin-1", url: "https://members.example.com/video/1" });
  await flush();

  const [answer] = answers(socket);
  assert.equal(answer.requestId, "signin-1");
  assert.deepEqual(answer.cookies, [{ name: "session", value: "abc", domain: "members.example.com", httpOnly: true }, { name: "theme", value: "dark", domain: "members.example.com" }]);
  assert.equal(answer.userAgent, "Mozilla/5.0 Arc");
});

test("a site with no cookies still gets an answer, with an empty list", async () => {
  const { socket } = await connected();

  await socket.reply({ type: "site.signIn", requestId: "signin-2", url: "https://nothing.example.org/" });
  await flush();

  assert.deepEqual(answers(socket)[0].cookies, []);
});

test("an address that isn't a web link gets no cookies", async () => {
  const { socket } = await connected();

  await socket.reply({ type: "site.signIn", requestId: "signin-3", url: "file:///Users/me/secret" });
  await socket.reply({ type: "site.signIn", requestId: "signin-4" });
  await flush();

  assert.deepEqual(answers(socket).map((answer) => answer.cookies), [[], []]);
});

test("a request without an ID is ignored", async () => {
  const { socket } = await connected();

  await socket.reply({ type: "site.signIn", url: "https://members.example.com/video/1" });
  await flush();

  assert.deepEqual(answers(socket), []);
});

test("answering a sign-in request asks the user for no permission", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "site.signIn", requestId: "signin-5", url: "https://members.example.com/" });
  await flush();

  assert.equal(chrome.permissions.requests ?? 0, 0);
});

test("the manifest asks for no permission the released extension lacked, so the update isn't disabled", async () => {
  const { readFile } = await import("node:fs/promises");
  const manifest = JSON.parse(await readFile(new URL("../manifest.json", import.meta.url), "utf8"));

  assert.deepEqual(manifest.permissions, ["activeTab", "alarms", "cookies", "downloads", "storage", "contextMenus", "notifications", "webRequest", "scripting"]);
  assert.deepEqual(manifest.host_permissions, ["https://*/*", "http://*/*"]);
});
