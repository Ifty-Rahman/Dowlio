import assert from "node:assert/strict";
import { test } from "node:test";
import { catchControls } from "../lib/popup-text.js";

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
