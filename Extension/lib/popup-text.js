import { hostOf, matchesSite } from "./catching.js";

export function popupText(status) {
  switch (status) {
    case "connected":
      return { headline: "Connected to Dowlio", detail: "Downloads from this browser can finish in Dowlio." };
    case "pairing":
      return {
        headline: "Type the code Dowlio shows",
        detail: "Dowlio shows a 6-digit code when this browser asks to connect. Type it here.",
        asksForCode: true,
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

export function sendPageControl({ status, tabUrl }) {
  if (!/^https?:/i.test(tabUrl ?? "")) return { shown: false };
  return { shown: true, enabled: status === "connected" };
}

export function pairingErrorText(error) {
  if (!error) return null;
  return error.left === 1 ? "That code didn't match. 1 try left." : `That code didn't match. ${error.left} tries left.`;
}

const DECLINE_MEMORY = 60 * 60 * 1000;

export function lastDeclineText(decline, now = Date.now()) {
  if (!decline || now - decline.at > DECLINE_MEMORY) return null;
  const why = {
    needsSignIn: decline.hadCookies
      ? "the site refused Dowlio, even with your cookies."
      : "the site refused Dowlio, and the browser had no cookies for it.",
    unsupported: "Dowlio can't download this kind of link.",
    error: "Dowlio couldn't reach the file.",
    noAnswer: "Dowlio didn't answer in time.",
  }[decline.reason];
  return why ? `${decline.host} stayed in the browser: ${why}` : null;
}
