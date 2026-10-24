import { popupText } from "./lib/popup-text.js";

const storage = chrome.storage.local;

async function render() {
  const { status, code } = await storage.get(["status", "code"]);
  const text = popupText(status);
  document.getElementById("headline").textContent = text.headline;
  document.getElementById("detail").textContent = text.detail;
  const codeView = document.getElementById("code");
  codeView.hidden = !(text.showsCode && code);
  codeView.textContent = code ?? "";
  document.getElementById("retry").hidden = !text.showsRetry;
}

document.getElementById("retry").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "pair.retry" });
});

chrome.storage.onChanged.addListener(render);
render();
