import assert from "node:assert/strict";
import { test } from "node:test";
import { catchControls, lastDeclineText } from "../lib/popup-text.js";

test("the catch controls show only while Dowlio is connected", () => {
  assert.equal(catchControls({ status: "disconnected", tabUrl: "https://example.com/" }).shown, false);
  assert.equal(catchControls({ status: "pairing", tabUrl: "https://example.com/" }).shown, false);
});

test("the switch mirrors what Dowlio last sent, and is on before Dowlio says", () => {
  assert.equal(catchControls({ status: "connected", catching: { catches: false, neverCatch: [] } }).catches, false);
  assert.equal(catchControls({ status: "connected" }).catches, true);
});

test("the current site can be added to the never-catch list", () => {
  const controls = catchControls({ status: "connected", catching: { catches: true, neverCatch: [] }, tabUrl: "https://www.mega.nz/file/abc" });
  assert.equal(controls.site, "mega.nz");
  assert.equal(controls.neverCaught, false);
  assert.equal(controls.siteText, "Never catch on mega.nz");
});

test("a site already on the list says its downloads stay in the browser", () => {
  const controls = catchControls({ status: "connected", catching: { catches: true, neverCatch: ["mega.nz"] }, tabUrl: "https://eu.mega.nz/" });
  assert.equal(controls.neverCaught, true);
  assert.equal(controls.siteText, "Downloads from eu.mega.nz stay in this browser.");
});

test("a page that isn't a website offers no site", () => {
  assert.equal(catchControls({ status: "connected", tabUrl: "chrome://extensions/" }).site, null);
  assert.equal(catchControls({ status: "connected" }).site, null);
});

test("the popup says in plain words why the last download stayed in the browser", () => {
  const now = 1_800_000_000_000;
  const at = now - 60_000;
  assert.equal(
    lastDeclineText({ host: "send.now", reason: "needsSignIn", hadCookies: true, at }, now),
    "send.now stayed in the browser: the site refused Dowlio, even with your sign-in.",
  );
  assert.equal(
    lastDeclineText({ host: "send.now", reason: "needsSignIn", hadCookies: false, at }, now),
    "send.now stayed in the browser: the site refused Dowlio, and the browser had no sign-in for it.",
  );
  assert.equal(
    lastDeclineText({ host: "files.net", reason: "unsupported", at }, now),
    "files.net stayed in the browser: the link gave a web page where your browser got a file.",
  );
  assert.equal(lastDeclineText({ host: "files.net", reason: "error", at }, now), "files.net stayed in the browser: Dowlio couldn't reach the file.");
  assert.equal(lastDeclineText({ host: "files.net", reason: "noAnswer", at }, now), "files.net stayed in the browser: Dowlio didn't answer in time.");
});

test("an old or missing note shows nothing", () => {
  const now = 1_800_000_000_000;
  assert.equal(lastDeclineText(undefined, now), null);
  assert.equal(lastDeclineText({ host: "a.com", reason: "error", at: now - 2 * 60 * 60 * 1000 }, now), null);
});
