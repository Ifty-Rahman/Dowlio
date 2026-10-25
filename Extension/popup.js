import { catchControls, popupText, signInControls } from "./lib/popup-text.js";
import { allowedOriginsIn } from "./lib/signin.js";

const storage = chrome.storage.local;
let tabUrl;

async function render() {
  const { status, code, catching } = await storage.get(["status", "code", "catching"]);
  const text = popupText(status);
  document.getElementById("headline").textContent = text.headline;
  document.getElementById("detail").textContent = text.detail;
  const codeView = document.getElementById("code");
  codeView.hidden = !(text.showsCode && code);
  codeView.textContent = code ?? "";
  document.getElementById("retry").hidden = !text.showsRetry;

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

async function renderSignIn() {
  const allowedOrigins = allowedOriginsIn(await chrome.permissions.getAll());
  const controls = signInControls({ tabUrl, allowedOrigins });
  document.getElementById("signin").hidden = !controls.origin && allowedOrigins.length === 0;
  const button = document.getElementById("use-signin");
  button.hidden = !controls.origin || controls.allowed;
  button.textContent = controls.buttonText ?? "";
  button.dataset.origin = controls.origin ?? "";
  document.getElementById("signin-heading").hidden = allowedOrigins.length === 0;
  const list = document.getElementById("signin-sites");
  list.replaceChildren(
    ...allowedOrigins.map((origin) => {
      const item = document.createElement("li");
      const name = document.createElement("span");
      name.textContent = new URL(origin).hostname;
      const remove = document.createElement("button");
      remove.textContent = "Remove";
      remove.setAttribute("aria-label", `Remove ${new URL(origin).hostname}`);
      remove.addEventListener("click", () => {
        chrome.runtime.sendMessage({ type: "signin.remove", origin });
      });
      item.append(name, remove);
      return item;
    }),
  );
}

document.getElementById("use-signin").addEventListener("click", (event) => {
  const origin = event.target.dataset.origin;
  if (!origin) return;
  chrome.permissions.request({ permissions: ["cookies"], origins: [`${origin}/*`] }).then(renderSignIn, renderSignIn);
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
chrome.permissions.onRemoved.addListener(renderSignIn);
chrome.permissions.onAdded.addListener(renderSignIn);
chrome.tabs
  .query({ active: true, currentWindow: true })
  .then(([tab]) => {
    tabUrl = tab?.url;
  })
  .catch(() => {})
  .finally(() => {
    render();
    renderSignIn();
  });
