import { browserName } from "./browser.js";
import { scanPage } from "./scan.js";

export const MENU_ITEM = "send-to-dowlio";
export const PAGE_MENU_ITEM = "send-page-to-dowlio";
export const RECEIPT_TIMEOUT = 5000;

export function startSending({ chrome, navigator, link, watching }) {
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

  async function sendLink(info, tab) {
    if (!link.isConnected()) return notify("Dowlio isn't running", "Open Dowlio to download with it.");
    const receipt = await link.request(
      "link.send",
      { url: info.linkUrl, referrer: info.pageUrl ?? tab?.url, browser: browserName(navigator), userAgent: navigator?.userAgent, cookies: await link.cookiesFor?.(info.linkUrl) },
      RECEIPT_TIMEOUT,
    );
    if (receipt?.type !== "link.received") noAnswer("link");
  }

  async function scan(tabId) {
    const frames = await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, func: scanPage }).catch(() => []);
    const media = [];
    const seen = new Set();
    const embeddedJson = [];
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
      embeddedJson.push(...(result.embeddedJson ?? []));
    }
    return { title, media, embeddedJson };
  }

  async function sendPage(tab) {
    if (!tab?.url) return;
    if (!link.isConnected()) return notify("Dowlio isn't running", "Open Dowlio to send this page.");
    const found = await scan(tab.id);
    const receipt = await link.request(
      "page.send",
      {
        url: tab.url,
        title: tab.title || found.title,
        browser: browserName(navigator),
        userAgent: navigator?.userAgent,
        cookies: await link.cookiesFor?.(tab.url),
        media: found.media,
        requests: watching?.requestsFor(tab.id) ?? [],
        embeddedJson: found.embeddedJson,
      },
      RECEIPT_TIMEOUT,
    );
    if (receipt?.type !== "page.received") noAnswer("page");
  }

  chrome.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId === MENU_ITEM && info.linkUrl) return sendLink(info, tab);
    if (info.menuItemId === PAGE_MENU_ITEM) return sendPage(tab);
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "page.send" || typeof message.tabId !== "number") return;
    chrome.tabs.get(message.tabId).then(sendPage, () => {});
  });
}
