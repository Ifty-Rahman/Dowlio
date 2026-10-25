import { browserName } from "./browser.js";

export const MENU_ITEM = "send-to-dowlio";
export const RECEIPT_TIMEOUT = 5000;

export function startSending({ chrome, navigator, link }) {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: MENU_ITEM, title: "Send to Dowlio", contexts: ["link"] });
  });

  function notify(title, message) {
    chrome.notifications.create("", { type: "basic", iconUrl: "icons/128.png", title, message });
  }

  function openDowlioFirst() {
    notify("Dowlio isn't running", "Open Dowlio to download with it.");
  }

  function noAnswer() {
    notify("Dowlio didn't answer", "Check that Dowlio is open, then send the link again.");
  }

  chrome.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId !== MENU_ITEM || !info.linkUrl) return;
    if (!link.isConnected()) return openDowlioFirst();
    const receipt = await link.request(
      "link.send",
      { url: info.linkUrl, referrer: info.pageUrl ?? tab?.url, browser: browserName(navigator), cookies: await link.cookiesFor?.(info.linkUrl) },
      RECEIPT_TIMEOUT,
    );
    if (receipt?.type !== "link.received") noAnswer();
  });
}
