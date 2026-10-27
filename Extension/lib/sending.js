import { browserName } from "./browser.js";
import { scanPage } from "./scan.js";

export const MENU_ITEM = "send-to-dowlio";
export const PAGE_MENU_ITEM = "send-page-to-dowlio";
export const RECEIPT_TIMEOUT = 5000;
export const CONNECT_WAIT = 3000;
export const SCAN_TIMEOUT = 4000;
export const VISIBILITY_CHECKS = 4;
export const VISIBILITY_TIMEOUT = 500;

export function startSending({ chrome, navigator, link, watching, timers = globalThis, now = Date.now }) {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: MENU_ITEM, title: "Send to Dowlio", contexts: ["link"] });
    chrome.contextMenus.create({ id: PAGE_MENU_ITEM, title: "Send to Dowlio", contexts: ["page"] });
  });

  function notify(title, message) {
    chrome.notifications.create("", { type: "basic", iconUrl: "icons/128.png", title, message });
  }

  function noAnswer(what) {
    notify("Dowlio didn't answer", `Check that Dowlio is open, then send the ${what} again.`);
  }

  async function reachable() {
    return link.isConnected() || (await link.whenConnected?.(CONNECT_WAIT)) === true;
  }

  function noteStep(url, step) {
    let host = "";
    try {
      host = new URL(url).hostname;
    } catch {}
    return chrome.storage.local.set({ lastSend: { host, step, at: now() } }).catch(() => {});
  }

  function withinTime(work, fallback, timeout = SCAN_TIMEOUT) {
    return new Promise((resolve) => {
      const timer = timers.setTimeout(() => resolve(fallback), timeout);
      work.then(
        (value) => {
          timers.clearTimeout(timer);
          resolve(value);
        },
        () => {
          timers.clearTimeout(timer);
          resolve(null);
        },
      );
    });
  }

  async function sendLink(info, tab) {
    if (!(await reachable())) return notify("Dowlio isn't running", "Open Dowlio to download with it.");
    const receipt = await link.request(
      "link.send",
      { url: info.linkUrl, referrer: info.pageUrl ?? tab?.url, browser: browserName(navigator), userAgent: navigator?.userAgent, cookies: await link.cookiesFor?.(info.linkUrl) },
      RECEIPT_TIMEOUT,
    );
    if (receipt?.type !== "link.received") noAnswer("link");
  }

  const TIMED_OUT = Symbol("timed out");

  async function scan(tabId) {
    const injected = Promise.resolve().then(() => chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func: scanPage }));
    const frames = await withinTime(injected, TIMED_OUT);
    if (frames === TIMED_OUT) return { title: "", media: [], players: [], embeddedJson: [], timedOut: true };
    const media = [];
    const seen = new Set();
    const embeddedJson = [];
    const players = [];
    let title = "";
    let groups = 0;
    for (const { result } of frames ?? []) {
      if (!result) continue;
      title ||= result.title ?? "";
      const offset = groups;
      for (const entry of result.media ?? []) {
        if (entry.group) groups = Math.max(groups, offset + entry.group);
        if (seen.has(entry.url)) continue;
        seen.add(entry.url);
        media.push(entry.group ? { ...entry, group: offset + entry.group } : entry);
      }
      for (const player of result.players ?? []) {
        groups = Math.max(groups, offset + player.group);
        players.push({ ...player, group: offset + player.group });
      }
      embeddedJson.push(...(result.embeddedJson ?? []));
    }
    const placed = /^Video \d+ of \d+$/;
    const numbered = players.map((player, index) => (placed.test(player.label) ? { ...player, label: `Video ${index + 1} of ${players.length}` } : player));
    return { title, media, players: numbered, embeddedJson };
  }

  async function sendPage(tab) {
    if (!tab?.url) return;
    try {
      await deliverPage(tab);
    } catch {
      await noteStep(tab.url, "error");
      notify("Dowlio couldn't send this page", "Reload the page, then send it again.");
    }
  }

  async function pageFields(tab, found) {
    return {
      url: tab.url,
      title: tab.title || found.title,
      browser: browserName(navigator),
      userAgent: navigator?.userAgent,
      cookies: await link.cookiesFor?.(tab.url),
      media: found.media,
      players: found.players,
      requests: watching?.requestsFor(tab.id) ?? [],
      embeddedJson: found.embeddedJson,
    };
  }

  async function deliverPage(tab) {
    await noteStep(tab.url, "started");
    if (!(await reachable())) {
      await noteStep(tab.url, "notConnected");
      return notify("Dowlio isn't running", "Open Dowlio to send this page.");
    }
    const found = await scan(tab.id);
    await noteStep(tab.url, found.timedOut ? "scanTimedOut" : "scanned");
    const sending = link.request("page.send", await pageFields(tab, found), RECEIPT_TIMEOUT);
    await noteStep(tab.url, found.timedOut ? "sentWithoutScan" : "sent");
    const receipt = await sending;
    if (receipt?.type !== "page.received") {
      await noteStep(tab.url, "noAnswer");
      return noAnswer("page");
    }
    await noteStep(tab.url, "received");
  }

  async function frontTab() {
    const focused = (await chrome.windows.getAll({ populate: true, windowTypes: ["normal", "popup", "app"] })).find((window) => window.focused);
    const window = focused ?? (await chrome.windows.getLastFocused({ populate: true, windowTypes: ["normal"] }));
    const active = window?.tabs?.find((tab) => tab.active);
    const pages = (window?.tabs ?? []).filter((tab) => /^https?:/i.test(tab.url ?? ""));
    const candidates = [...new Set([active, ...pages.sort((a, b) => (b.lastAccessed ?? 0) - (a.lastAccessed ?? 0))])]
      .filter((tab) => pages.includes(tab))
      .slice(0, VISIBILITY_CHECKS);
    if (candidates.every((tab) => tab === active)) return active;
    const visible = await Promise.all(candidates.map((tab) => isOnScreen(tab.id)));
    return candidates[visible.indexOf(true)] ?? active;
  }

  async function isOnScreen(tabId) {
    const asked = Promise.resolve().then(() => chrome.scripting.executeScript({ target: { tabId }, func: () => document.visibilityState }));
    const frames = await withinTime(asked, null, VISIBILITY_TIMEOUT);
    return frames?.[0]?.result === "visible";
  }

  async function scanFront(requestId) {
    const tab = await frontTab().catch(() => undefined);
    if (!/^https?:/i.test(tab?.url ?? "")) return link.reply("page.none", requestId, { reason: "noTab" });
    await noteStep(tab.url, "asked");
    const found = await scan(tab.id);
    link.reply("page.send", requestId, await pageFields(tab, found));
    await noteStep(tab.url, "sent");
  }

  chrome.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId === MENU_ITEM && info.linkUrl) return sendLink(info, tab);
    if (info.menuItemId === PAGE_MENU_ITEM) return sendPage(tab);
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "page.send" || typeof message.tabId !== "number") return;
    chrome.tabs.get(message.tabId).then(sendPage, () => {});
  });

  return { scanFront };
}
