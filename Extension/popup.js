import { catchControls, lastDeclineText, pairingErrorText, popupText, sendPageControl } from "./lib/popup-text.js";

const storage = chrome.storage.local;
let tabUrl;
let tabId;

async function render() {
  const { status, catching, lastDecline, pairingError } = await storage.get(["status", "catching", "lastDecline", "pairingError"]);
  const text = popupText(status);
  document.getElementById("headline").textContent = text.headline;
  document.getElementById("detail").textContent = text.detail;
  const codeForm = document.getElementById("code-form");
  const wasHidden = codeForm.hidden;
  codeForm.hidden = !text.asksForCode;
  if (text.asksForCode && wasHidden) document.getElementById("code").focus();
  const codeError = pairingErrorText(pairingError);
  const errorView = document.getElementById("code-error");
  errorView.hidden = !codeError;
  errorView.textContent = codeError ?? "";
  document.getElementById("retry").hidden = !text.showsRetry;
  const note = lastDeclineText(lastDecline);
  const noteView = document.getElementById("last-decline");
  noteView.hidden = !note;
  noteView.textContent = note ?? "";

  const sending = sendPageControl({ status, tabUrl });
  const sendPage = document.getElementById("send-page");
  sendPage.hidden = !sending.shown;
  sendPage.disabled = !sending.enabled;

  const controls = catchControls({ status, catching, tabUrl });
  document.getElementById("catching").hidden = !controls.shown;
  if (!controls.shown) return;
  document.getElementById("catches").checked = controls.catches;
  const neverCatch = document.getElementById("never-catch");
  const neverCaught = document.getElementById("never-caught");
  neverCatch.hidden = !controls.site || controls.neverCaught;
  neverCaught.hidden = !controls.site || !controls.neverCaught;
  neverCatch.textContent = controls.siteText ?? "";
  neverCaught.textContent = controls.siteText ?? "";
  neverCatch.dataset.site = controls.site ?? "";
}

document.getElementById("send-page").addEventListener("click", () => {
  if (typeof tabId !== "number") return;
  chrome.runtime.sendMessage({ type: "page.send", tabId });
  window.close();
});

document.getElementById("code-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const field = document.getElementById("code");
  const code = field.value.replace(/\s/g, "");
  if (!/^\d{6}$/.test(code)) return;
  chrome.runtime.sendMessage({ type: "pair.code", code });
  field.value = "";
});

document.getElementById("retry").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "pair.retry" });
});

document.getElementById("catches").addEventListener("change", (event) => {
  chrome.runtime.sendMessage({ type: "settings.change", catches: event.target.checked });
});

document.getElementById("never-catch").addEventListener("click", (event) => {
  const site = event.target.dataset.site;
  if (site) chrome.runtime.sendMessage({ type: "settings.change", neverCatchSite: site });
});

chrome.storage.onChanged.addListener(render);
chrome.tabs
  .query({ active: true, currentWindow: true })
  .then(([tab]) => {
    tabUrl = tab?.url;
    tabId = tab?.id;
  })
  .catch(() => {})
  .finally(render);
