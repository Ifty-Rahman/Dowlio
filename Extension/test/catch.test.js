import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected() {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const timers = new FakeTimers();
  const net = fakeSockets();
  const navigator = { ...navigatorLike(), userAgent: "Mozilla/5.0 Arc" };
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator });
  await flush();
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  return { chrome, timers, net, socket: net.last() };
}

function download(overrides = {}) {
  return {
    id: 7,
    url: "https://example.com/get/42",
    finalUrl: "https://cdn.example.com/files/Report.pdf",
    referrer: "https://example.com/reports",
    filename: "/Users/me/Downloads/Report.pdf",
    mime: "application/pdf",
    totalBytes: 2048,
    incognito: false,
    state: "in_progress",
    ...overrides,
  };
}

const offers = (socket) => socket.sent.filter((message) => message.type === "catch.offer");

test("a download is paused and offered to Dowlio with everything Dowlio needs to fetch it", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download());

  assert.deepEqual(chrome.downloads.calls, [["pause", 7]]);
  const offer = offers(socket)[0];
  assert.equal(offer.url, "https://example.com/get/42");
  assert.equal(offer.finalUrl, "https://cdn.example.com/files/Report.pdf");
  assert.equal(offer.referrer, "https://example.com/reports");
  assert.equal(offer.mime, "application/pdf");
  assert.equal(offer.fileName, "Report.pdf");
  assert.equal(offer.totalBytes, 2048);
  assert.equal(offer.browserPath, "/Users/me/Downloads/Report.pdf");
  assert.equal(offer.userAgent, "Mozilla/5.0 Arc");
});

test("an accepted download is cancelled and erased from the browser", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["cancel", 7], ["erase", 7]]);
});

test("a declined download resumes in the browser", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.declined", reason: "unsupported", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["resume", 7]]);
});

test("a reply to some other request leaves the download waiting", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.accepted", requestId: "someone-else" });

  assert.deepEqual(chrome.downloads.calls, [["pause", 7]]);
});

test("no answer within 5 seconds resumes the download in the browser", async () => {
  const { chrome, timers } = await connected();
  await chrome.downloads.create(download());

  await timers.advance(4999);
  assert.deepEqual(chrome.downloads.calls, [["pause", 7]]);
  await timers.advance(1);

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["resume", 7]]);
});

test("losing Dowlio while it decides resumes the download at once", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.fail();

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["resume", 7]]);
});

for (const [name, item] of [
  ["a blob: link", { url: "blob:https://mega.nz/1234", finalUrl: "blob:https://mega.nz/1234" }],
  ["a data: link", { url: "data:text/csv;base64,YQ==", finalUrl: "data:text/csv;base64,YQ==" }],
  ["a file: link", { url: "file:///Users/me/a.zip", finalUrl: "file:///Users/me/a.zip" }],
  ["an incognito download", { incognito: true }],
  ["a download Dowlio Connect started itself", { byExtensionId: "abcdefghijklmnopabcdefghijklmnop" }],
]) {
  test(`${name} stays in the browser untouched`, async () => {
    const { chrome, socket } = await connected();

    await chrome.downloads.create(download(item));

    assert.deepEqual(chrome.downloads.calls, []);
    assert.equal(offers(socket).length, 0);
  });
}

test("every download stays in the browser while Dowlio isn't connected", async () => {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();

  await chrome.downloads.create(download());

  assert.deepEqual(chrome.downloads.calls, []);
});

test("a download whose name comes from the save dialog is offered once the user picks it", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download({ filename: "" }));
  assert.equal(offers(socket).length, 0);
  await chrome.downloads.change({ id: 7, filename: { previous: "", current: "/Users/me/Taxes/Return.pdf" } });

  assert.equal(offers(socket)[0].browserPath, "/Users/me/Taxes/Return.pdf");
  assert.equal(offers(socket)[0].fileName, "Return.pdf");
});

test("a save dialog the user cancels sends nothing to Dowlio", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download({ filename: "" }));
  await chrome.downloads.change({ id: 7, state: { previous: "in_progress", current: "interrupted" }, error: { current: "USER_CANCELED" } });

  assert.equal(offers(socket).length, 0);
  assert.deepEqual(chrome.downloads.calls, [["pause", 7]]);
});

test("a save-dialog name that arrives while the download is being paused is still offered", async () => {
  const { chrome, socket } = await connected();
  chrome.downloads.whilePausing = () =>
    chrome.downloads.change({ id: 7, filename: { previous: "", current: "/Users/me/Taxes/Return.pdf" } });

  await chrome.downloads.create(download({ filename: "" }));

  assert.equal(offers(socket)[0].browserPath, "/Users/me/Taxes/Return.pdf");
});

test("a download that fails before it gets a name is resumed rather than left paused", async () => {
  const { chrome, socket } = await connected();

  await chrome.downloads.create(download({ filename: "" }));
  await chrome.downloads.change({ id: 7, error: { current: "NETWORK_FAILED" } });

  assert.equal(offers(socket).length, 0);
  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["resume", 7]]);
});

test("an accepted download is erased from the browser even when cancelling it fails", async () => {
  const { chrome, socket } = await connected();
  chrome.downloads.failing.add("cancel");

  await chrome.downloads.create(download());
  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["pause", 7], ["cancel", 7], ["erase", 7]]);
});
