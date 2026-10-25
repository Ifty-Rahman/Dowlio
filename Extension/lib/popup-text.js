import { hostOf, matchesSite } from "./catching.js";
import { originOf } from "./signin.js";

export function popupText(status) {
  switch (status) {
    case "connected":
      return { headline: "Connected to Dowlio", detail: "Downloads from this browser can finish in Dowlio." };
    case "pairing":
      return {
        headline: "Allow this browser in Dowlio",
        detail: "Dowlio is asking whether to connect. Allow it only if Dowlio shows this code.",
        showsCode: true,
      };
    case "denied":
      return { headline: "Dowlio didn't allow this browser", detail: "Ask again to show the request in Dowlio.", showsRetry: true };
    default:
      return { headline: "Dowlio isn't running", detail: "Open Dowlio, and Dowlio Connect connects on its own." };
  }
}

export function catchControls({ status, catching, tabUrl }) {
  if (status !== "connected") return { shown: false };
  const catches = catching?.catches !== false;
  const neverCatch = catching?.neverCatch ?? [];
  const site = /^https?:/i.test(tabUrl ?? "") ? hostOf(tabUrl) : "";
  if (!site) return { shown: true, catches, site: null };
  const neverCaught = matchesSite(site, neverCatch);
  return {
    shown: true,
    catches,
    site,
    neverCaught,
    siteText: neverCaught ? `Downloads from ${site} stay in this browser.` : `Never catch on ${site}`,
  };
}

export function signInControls({ tabUrl, allowedOrigins }) {
  const origin = originOf(tabUrl ?? "");
  if (!origin) return { origin: null };
  const allowed = allowedOrigins.includes(origin);
  return { origin, allowed, buttonText: `Use my sign-in on ${new URL(origin).hostname}` };
}
