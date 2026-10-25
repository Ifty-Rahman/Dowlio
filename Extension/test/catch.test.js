import assert from "node:assert/strict";
import { test } from "node:test";
import { startWorker } from "../lib/worker.js";
import { fakeChrome, fakeSockets, FakeTimers, flush, navigatorLike } from "./fakes.js";

async function connected({ clock = { time: 0 } } = {}) {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const timers = new FakeTimers();
  const net = fakeSockets();
  const navigator = { ...navigatorLike(), userAgent: "Mozilla/5.0 Arc" };
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator, now: () => clock.time });
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

test("a download is cancelled before the browser can show it, then offered to Dowlio with everything Dowlio needs", async () => {
  const { chrome, socket } = await connected();

  chrome.downloads.createNow(download({ filename: "" }));
  const callsBeforeAnyWait = [...chrome.downloads.calls];
  await flush();
  await flush();

  assert.deepEqual(callsBeforeAnyWait, [["cancel", 7]]);
  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
  const offer = offers(socket)[0];
  assert.equal(offer.url, "https://example.com/get/42");
  assert.equal(offer.finalUrl, "https://cdn.example.com/files/Report.pdf");
  assert.equal(offer.referrer, "https://example.com/reports");
  assert.equal(offer.mime, "application/pdf");
  assert.equal(offer.totalBytes, 2048);
  assert.equal(offer.userAgent, "Mozilla/5.0 Arc");
  assert.equal(offer.browserPath, undefined);
});

test("an accepted download stays cancelled and erased from the browser", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
});

test("Dowlio hears that the browser let go of an accepted download", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());
  const requestId = offers(socket)[0].requestId;

  await socket.reply({ type: "catch.accepted", requestId });

  const released = socket.sent.filter((message) => message.type === "catch.released");
  assert.deepEqual(released.map((message) => message.requestId), [requestId]);
  assert.equal(chrome.downloads.calls[0][0], "cancel");
});

test("a declined download never tells Dowlio the browser let go", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.declined", reason: "unsupported", requestId: offers(socket)[0].requestId });

  assert.equal(socket.sent.filter((message) => message.type === "catch.released").length, 0);
});

test("a declined download starts again in the browser and says why", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.declined", reason: "unsupported", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7], ["download", "https://example.com/get/42"]]);
  assert.equal(offers(socket).length, 1);
  assert.equal((await chrome.storage.local.get("lastDecline")).lastDecline.reason, "unsupported");
});

test("a reply to some other request leaves the download waiting for Dowlio", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.accepted", requestId: "someone-else" });

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
});

test("no answer within 15 seconds starts the download again in the browser", async () => {
  const { chrome, timers } = await connected();
  await chrome.downloads.create(download());

  await timers.advance(14999);
  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
  await timers.advance(1);

  assert.deepEqual(chrome.downloads.calls.at(-1), ["download", "https://example.com/get/42"]);
  assert.equal((await chrome.storage.local.get("lastDecline")).lastDecline.reason, "noAnswer");
});

test("losing Dowlio while it decides starts the download again in the browser at once", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());

  await socket.fail();

  assert.deepEqual(chrome.downloads.calls.at(-1), ["download", "https://example.com/get/42"]);
});

test("a declined posted download is posted again by the browser", async () => {
  const { chrome, socket } = await connected();
  const url = "https://send.now/bazoiwepu9vx";
  browserAsks(chrome, {
    url,
    method: "POST",
    body: { formData: { op: ["download2"] } },
    headers: [{ name: "Content-Type", value: "application/x-www-form-urlencoded" }],
  });
  await chrome.downloads.create(download({ url, finalUrl: url }));

  await socket.reply({ type: "catch.declined", reason: "error", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.started.at(-1), {
    url,
    method: "POST",
    body: "op=download2",
    headers: [{ name: "Content-Type", value: "application/x-www-form-urlencoded" }],
  });
});

for (const [name, item] of [
  ["a blob: link", { url: "blob:https://mega.nz/1234", finalUrl: "blob:https://mega.nz/1234" }],
  ["a data: link", { url: "data:text/csv;base64,YQ==", finalUrl: "data:text/csv;base64,YQ==" }],
  ["a file: link", { url: "file:///Users/me/a.zip", finalUrl: "file:///Users/me/a.zip" }],
  ["an incognito download", { incognito: true }],
  ["a download the browser says Dowlio Connect started", { byExtensionId: "abcdefghijklmnopabcdefghijklmnop" }],
]) {
  test(`${name} stays in the browser untouched`, async () => {
    const { chrome, socket } = await connected();

    await chrome.downloads.create(download(item));

    assert.deepEqual(chrome.downloads.calls, []);
    assert.equal(offers(socket).length, 0);
  });
}

test("every download stays in the browser while Dowlio isn't running", async () => {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();
  for (let attempt = 0; attempt < 4; attempt += 1) await net.last().fail();

  await chrome.downloads.create(download());

  assert.deepEqual(chrome.downloads.calls, []);
});

test("an accepted download is erased from the browser even when cancelling it fails", async () => {
  const { chrome, socket } = await connected();
  chrome.downloads.failing.add("cancel");

  await chrome.downloads.create(download());
  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
});

test("Download in Browser Instead starts the file in the browser without offering it to Dowlio again", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "browser.download", url: "https://cdn.example.com/files/Report.pdf" });

  assert.deepEqual(chrome.downloads.calls, [["download", "https://cdn.example.com/files/Report.pdf"]]);
  assert.equal(offers(socket).length, 0);
});

test("the same link clicked again later is offered to Dowlio as usual", async () => {
  const { chrome, socket } = await connected();
  await socket.reply({ type: "browser.download", url: "https://cdn.example.com/files/Report.pdf" });

  await chrome.downloads.create(download({ id: 8, url: "https://cdn.example.com/files/Report.pdf" }));

  assert.equal(offers(socket).length, 1);
});

test("a hand-back the browser never started stops blocking that link after a minute", async () => {
  const clock = { time: 0 };
  const { chrome, socket } = await connected({ clock });
  chrome.downloads.download = async () => 101;
  await socket.reply({ type: "browser.download", url: "https://cdn.example.com/files/Report.pdf" });

  clock.time = 61000;
  await chrome.downloads.create(download({ id: 9, url: "https://cdn.example.com/files/Report.pdf" }));

  assert.equal(offers(socket).length, 1);
});

test("a caught download Dowlio couldn't start goes back to the browser and says why", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());
  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  await socket.reply({ type: "browser.download", url: "https://example.com/get/42", reason: "needsSignIn" });

  assert.deepEqual(chrome.downloads.calls.at(-1), ["download", "https://example.com/get/42"]);
  assert.equal(offers(socket).length, 1);
  const { lastDecline } = await chrome.storage.local.get("lastDecline");
  assert.equal(lastDecline.host, "cdn.example.com");
  assert.equal(lastDecline.reason, "needsSignIn");
});

test("a posted download Dowlio couldn't start is posted again by the browser", async () => {
  const { chrome, socket } = await connected();
  const url = "https://send.now/bazoiwepu9vx";
  browserAsks(chrome, {
    url,
    method: "POST",
    body: { formData: { op: ["download2"], id: ["bazoiwepu9vx"] } },
    headers: [{ name: "Content-Type", value: "application/x-www-form-urlencoded" }, { name: "Origin", value: "https://send.now" }],
  });
  await chrome.downloads.create(download({ url, finalUrl: url }));
  await socket.reply({ type: "catch.accepted", requestId: offers(socket)[0].requestId });

  await socket.reply({ type: "browser.download", url, reason: "error" });

  assert.deepEqual(chrome.downloads.started.at(-1), {
    url,
    method: "POST",
    body: "op=download2&id=bazoiwepu9vx",
    headers: [{ name: "Content-Type", value: "application/x-www-form-urlencoded" }],
  });
});

test("Download in Browser Instead leaves no note about why the download stayed", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "browser.download", url: "https://cdn.example.com/files/Report.pdf" });

  assert.equal((await chrome.storage.local.get("lastDecline")).lastDecline, undefined);
});

test("a hand-back that isn't a web link is ignored", async () => {
  const { chrome, socket } = await connected();

  await socket.reply({ type: "browser.download", url: "file:///etc/passwd" });

  assert.deepEqual(chrome.downloads.calls, []);
});

function browserAsks(chrome, { requestId = "r1", url, method = "GET", type = "main_frame", body, headers = [] }) {
  chrome.webRequest.fire("onBeforeRequest", { requestId, url, method, type, tabId: 1, requestBody: body });
  chrome.webRequest.fire("onSendHeaders", { requestId, url, method, type, tabId: 1, requestHeaders: headers });
}

test("a download the browser got by posting a form is offered with that form and the headers the browser sent", async () => {
  const { chrome, socket } = await connected();
  const url = "https://send.now/bazoiwepu9vx";
  browserAsks(chrome, {
    url,
    method: "POST",
    body: { formData: { op: ["download2"], id: ["bazoiwepu9vx"], rand: ["a b&c"] } },
    headers: [
      { name: "Content-Type", value: "application/x-www-form-urlencoded" },
      { name: "Origin", value: "https://send.now" },
      { name: "Referer", value: "https://send.now/bazoiwepu9vx" },
      { name: "User-Agent", value: "Mozilla/5.0 Dia" },
      { name: "Cookie", value: "cf_clearance=secret" },
      { name: "X-Requested-With", value: "XMLHttpRequest" },
    ],
  });

  await chrome.downloads.create(download({ url, finalUrl: url, referrer: "" }));

  const offer = offers(socket)[0];
  assert.equal(offer.request.method, "POST");
  assert.equal(Buffer.from(offer.request.body, "base64").toString(), "op=download2&id=bazoiwepu9vx&rand=a+b%26c");
  assert.deepEqual(offer.request.headers, [
    { name: "Content-Type", value: "application/x-www-form-urlencoded" },
    { name: "Origin", value: "https://send.now" },
    { name: "X-Requested-With", value: "XMLHttpRequest" },
  ]);
  assert.equal(offer.referrer, "https://send.now/bazoiwepu9vx");
  assert.equal(offer.userAgent, "Mozilla/5.0 Dia");
});

for (const [name, body] of [
  ["a posted body over 64 KB", { raw: [{ bytes: new Uint8Array(64 * 1024 + 1).fill(97).buffer }] }],
  ["a posted file", { raw: [{ bytes: new TextEncoder().encode("--b\r\n").buffer }, { file: "/Users/me/photo.jpg" }] }],
  ["a posted binary body", { raw: [{ bytes: new Uint8Array([0xff, 0xfe, 0x00, 0x81]).buffer }] }],
]) {
  test(`a download that came from ${name} stays in the browser, since neither Dowlio nor the browser could post it again`, async () => {
    const { chrome, socket } = await connected();
    const url = "https://files.example.com/export";
    browserAsks(chrome, { url, method: "POST", body, headers: [{ name: "Content-Type", value: "application/octet-stream" }] });

    await chrome.downloads.create(download({ url, finalUrl: url }));

    assert.deepEqual(chrome.downloads.calls, []);
    assert.equal(offers(socket).length, 0);
  });
}

test("a posted body of exactly 64 KB is still caught", async () => {
  const { chrome, socket } = await connected();
  const url = "https://files.example.com/export";
  browserAsks(chrome, { url, method: "POST", body: { raw: [{ bytes: new Uint8Array(64 * 1024).fill(97).buffer }] } });

  await chrome.downloads.create(download({ url, finalUrl: url }));

  assert.equal(Buffer.from(offers(socket)[0].request.body, "base64").length, 64 * 1024);
});

test("a failure after the browser let go still starts the download again in the browser", async () => {
  const { chrome, socket } = await connected();
  await chrome.downloads.create(download());
  chrome.storage.local.set = async () => {
    throw new Error("storage is full");
  };

  await socket.reply({ type: "catch.declined", reason: "unsupported", requestId: offers(socket)[0].requestId });

  assert.deepEqual(chrome.downloads.calls.at(-1), ["download", "https://example.com/get/42"]);
});

test("why a download stayed in the browser is stamped with the extension's clock", async () => {
  const clock = { time: 1_800_000_000_000 };
  const { chrome, socket } = await connected({ clock });
  await chrome.downloads.create(download());

  await socket.reply({ type: "catch.declined", reason: "error", requestId: offers(socket)[0].requestId });

  assert.equal((await chrome.storage.local.get("lastDecline")).lastDecline.at, clock.time);
});

test("a multipart form is sent again with the browser's own boundary", async () => {
  const { chrome, socket } = await connected();
  const url = "https://files.example.com/get";
  browserAsks(chrome, {
    url,
    method: "POST",
    body: { formData: { id: ["42"] } },
    headers: [{ name: "Content-Type", value: "multipart/form-data; boundary=----Edge7" }],
  });

  await chrome.downloads.create(download({ url, finalUrl: url }));

  const body = Buffer.from(offers(socket)[0].request.body, "base64").toString();
  assert.equal(body, '------Edge7\r\nContent-Disposition: form-data; name="id"\r\n\r\n42\r\n------Edge7--\r\n');
});

test("a raw posted body is sent again byte for byte", async () => {
  const { chrome, socket } = await connected();
  const url = "https://api.example.com/export";
  browserAsks(chrome, { url, method: "POST", body: { raw: [{ bytes: new TextEncoder().encode('{"id":42}').buffer }] } });

  await chrome.downloads.create(download({ url, finalUrl: url }));

  assert.equal(Buffer.from(offers(socket)[0].request.body, "base64").toString(), '{"id":42}');
});

test("a download that came through a redirect is offered with the request for the file itself", async () => {
  const { chrome, socket } = await connected();
  browserAsks(chrome, { requestId: "r9", url: "https://example.com/get/42", headers: [{ name: "X-Token", value: "first" }] });
  browserAsks(chrome, { requestId: "r9", url: "https://cdn.example.com/files/Report.pdf", headers: [{ name: "X-Token", value: "second" }] });

  await chrome.downloads.create(download());

  assert.deepEqual(offers(socket)[0].request, { method: "GET", headers: [{ name: "X-Token", value: "second" }] });
});

test("a plain download with nothing worth sending again carries no request", async () => {
  const { chrome, socket } = await connected();
  browserAsks(chrome, { url: "https://cdn.example.com/files/Report.pdf", headers: [{ name: "Accept", value: "*/*" }] });

  await chrome.downloads.create(download());

  assert.equal(offers(socket)[0].request, undefined);
});

test("a download that starts while Dowlio Connect is still connecting waits for the link, then is offered", async () => {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers: new FakeTimers(), navigator: navigatorLike() });
  await flush();

  await chrome.downloads.create(download());
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });
  for (let turn = 0; turn < 5; turn += 1) await flush();

  assert.deepEqual(chrome.downloads.calls, [["cancel", 7], ["erase", 7]]);
  assert.equal(offers(net.last()).length, 1);
});

test("a download stays in the browser untouched when Dowlio doesn't connect within 3 seconds", async () => {
  const chrome = fakeChrome({ stored: { token: "tok" } });
  const net = fakeSockets();
  const timers = new FakeTimers();
  startWorker({ chrome, WebSocket: net.FakeWebSocket, timers, navigator: navigatorLike() });
  await flush();

  await chrome.downloads.create(download());
  await timers.advance(3000);
  await net.last().accept();
  await net.last().reply({ type: "hello.ok" });

  assert.deepEqual(chrome.downloads.calls, []);
  assert.equal(offers(net.last()).length, 0);
});
