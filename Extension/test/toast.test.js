import assert from "node:assert/strict";
import { test } from "node:test";
import { parseHTML } from "linkedom";
import { showToast } from "../lib/toast.js";

function page() {
  const { document } = parseHTML("<!doctype html><html><body></body></html>");
  const timers = [];
  globalThis.document = document;
  globalThis.setTimeout = (run, delay) => timers.push({ run, delay }) && timers.length;
  globalThis.clearTimeout = () => {};
  return { document, timers };
}

test("the toast appears on the page, then goes", (t) => {
  const { setTimeout, clearTimeout } = globalThis;
  t.after(() => Object.assign(globalThis, { setTimeout, clearTimeout, document: undefined }));
  const { document, timers } = page();

  showToast("Dowlio isn't running", "Open Dowlio to download with it.", "dowlio-connect-toast", 6000);

  const host = document.getElementById("dowlio-connect-toast");
  assert.ok(host);
  assert.equal(timers.at(-1).delay, 6000);
  timers.at(-1).run();
  assert.equal(document.getElementById("dowlio-connect-toast"), null);
});

test("a second toast replaces the first", (t) => {
  const { setTimeout, clearTimeout } = globalThis;
  t.after(() => Object.assign(globalThis, { setTimeout, clearTimeout, document: undefined }));
  const { document } = page();

  showToast("Dowlio didn't answer", "Check that Dowlio is open, then send the link again.");
  showToast("Dowlio isn't running", "Open Dowlio to download with it.");

  assert.equal(document.querySelectorAll("#dowlio-connect-toast").length, 1);
});
