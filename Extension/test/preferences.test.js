import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected({ stored = {} } = {}) {
  const chrome = fakeChrome({ stored: { token: "tok", ...stored } });
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  return { chrome, socket: net.last() };
}

function download(overrides = {}) {
  return {
    id: 7,
    url: "https://cdn.example.com/files/Report.pdf",
    finalUrl: "https://cdn.example.com/files/Report.pdf",
    referrer: "https://reports.example.org/2026",
    filename: "/Users/me/Downloads/Report.pdf",
    mime: "application/pdf",
    incognito: false,
    state: "in_progress",
    ...overrides,
  };
}

const offers = (socket) => socket.sent.filter((message) => message.type === "catch.offer");

test("with catching turned off in Dowlio, downloads stay in the browser untouched", async () => {
  const { chrome, socket } = await connected();
  await socket.reply({ type: "settings.update", catches: false, neverCatch: [] });

  await chrome.downloads.create(download());

  assert.deepEqual(chrome.downloads.calls, []);
  assert.equal(offers(socket).length, 0);
});

test("turning catching back on offers downloads again", async () => {
  const { chrome, socket } = await connected();
  await socket.reply({ type: "settings.update", catches: false, neverCatch: [] });
  await socket.reply({ type: "settings.update", catches: true, neverCatch: [] });

  await chrome.downloads.create(download());

  assert.equal(offers(socket).length, 1);
});

for (const [name, site] of [
  ["the page it was clicked on", "example.org"],
  ["the server it comes from", "example.com"],
  ["exactly the page's host", "reports.example.org"],
]) {
  test(`a download is left alone when ${name} is on the never-catch list`, async () => {
    const { chrome, socket } = await connected();
    await socket.reply({ type: "settings.update", catches: true, neverCatch: [site] });

    await chrome.downloads.create(download());

    assert.deepEqual(chrome.downloads.calls, []);
  });
}

test("a site whose name only ends the same way as a listed site is still caught", async () => {
  const { chrome, socket } = await connected();
  await socket.reply({ type: "settings.update", catches: true, neverCatch: ["ample.com"] });

  await chrome.downloads.create(download({ referrer: "https://example.net/" }));

  assert.equal(offers(socket).length, 1);
});

test("the last settings Dowlio sent apply after the browser restarts the worker", async () => {
  const { chrome, socket } = await connected({ stored: { catching: { catches: false, neverCatch: [] } } });

  await chrome.downloads.create(download());

  assert.equal(offers(socket).length, 0);
});

test("settings from Dowlio are kept for the popup", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "settings.update", catches: false, neverCatch: ["mega.nz"] });

  assert.deepEqual(await chrome.storage.local.get("catching"), { catching: { catches: false, neverCatch: ["mega.nz"] } });
});

test("a change in the popup goes to Dowlio, which decides and sends it back", async () => {
  const { chrome, socket } = await connected();

  chrome.runtime.sendMessage({ type: "settings.change", neverCatchSite: "mega.nz" });
  chrome.runtime.sendMessage({ type: "settings.change", catches: false });
  await flush();

  const changes = socket.sent.filter((message) => message.type === "settings.change");
  assert.deepEqual(changes.map(({ neverCatchSite, catches }) => ({ neverCatchSite, catches })), [
    { neverCatchSite: "mega.nz", catches: undefined },
    { neverCatchSite: undefined, catches: false },
  ]);
});

test("a download right after the worker wakes waits for the saved settings", async () => {
  const chrome = fakeChrome({ stored: { token: "tok", catching: { catches: true, neverCatch: ["example.org"] } } });
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });

  await chrome.downloads.create(download());

  assert.deepEqual(chrome.downloads.calls, []);
});

test("an update from Dowlio wins over settings saved earlier", async () => {
  const { chrome, socket } = await connected({ stored: { catching: { catches: false, neverCatch: [] } } });

  await socket.reply({ type: "settings.update", catches: true, neverCatch: [] });
  await chrome.downloads.create(download());

  assert.equal(offers(socket).length, 1);
});
