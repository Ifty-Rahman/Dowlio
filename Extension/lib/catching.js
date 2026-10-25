export const CATCH_TIMEOUT = 5000;
export const HAND_BACK_MARK_LIFETIME = 60000;

function isWebLink(link) {
  return /^https?:/i.test(link ?? "");
}

function sameLink(url) {
  try {
    return new URL(url).href;
  } catch {
    return url;
  }
}

export function hostOf(url) {
  try {
    return new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function matchesSite(host, sites) {
  return sites.some((site) => host === site || host.endsWith(`.${site}`));
}

function isNeverCaught(item, sites) {
  return [item.url, item.finalUrl, item.referrer].map(hostOf).some((host) => host && matchesSite(host, sites));
}

function baseName(path) {
  return path.split(/[\\/]/).pop();
}

export function startCatching({ chrome, link, navigator, now = Date.now }) {
  const downloads = chrome.downloads;
  const waitingForName = new Map();
  const handedBack = new Map();

  function wasHandedBack(url) {
    const key = sameLink(url);
    const markedAt = handedBack.get(key);
    handedBack.delete(key);
    return markedAt !== undefined && now() - markedAt < HAND_BACK_MARK_LIFETIME;
  }

  function chosenPath(id) {
    return new Promise((resolve) => waitingForName.set(id, resolve));
  }

  function failedOnItsOwn(delta) {
    const error = delta.error?.current;
    return Boolean(error) && !error.startsWith("USER_");
  }

  downloads.onChanged.addListener((delta) => {
    const resolve = waitingForName.get(delta.id);
    if (!resolve) return;
    if (delta.filename?.current) {
      waitingForName.delete(delta.id);
      resolve({ path: delta.filename.current });
    } else if (delta.state?.current === "interrupted" || delta.state?.current === "complete" || delta.error) {
      waitingForName.delete(delta.id);
      resolve({ resume: failedOnItsOwn(delta) });
    }
  });

  async function offer(item) {
    const source = item.finalUrl || item.url;
    if (item.byExtensionId === chrome.runtime.id || wasHandedBack(item.url)) return;
    if (!isWebLink(item.url) || !isWebLink(source)) return;
    if (item.incognito || !link.isConnected()) return;
    const { catches, neverCatch } = await link.preferences();
    if (!catches || isNeverCaught(item, neverCatch)) return;
    const named = item.filename ? Promise.resolve({ path: item.filename }) : chosenPath(item.id);
    let paused = true;
    await downloads.pause(item.id).catch(() => {
      paused = false;
    });
    const { path, resume } = await named;
    if (!path) {
      if (resume) await downloads.resume(item.id).catch(() => {});
      return;
    }
    if (!paused) await downloads.pause(item.id).catch(() => {});
    const reply = await link.request(
      "catch.offer",
      {
        url: item.url,
        finalUrl: item.finalUrl || item.url,
        referrer: item.referrer || undefined,
        mime: item.mime || undefined,
        fileName: baseName(path),
        totalBytes: item.totalBytes > 0 ? item.totalBytes : undefined,
        browserPath: path,
        userAgent: navigator?.userAgent,
      },
      CATCH_TIMEOUT,
    );
    if (reply?.type === "catch.accepted") {
      await downloads.cancel(item.id).catch(() => {});
      await downloads.erase({ id: item.id }).catch(() => {});
    } else {
      await downloads.resume(item.id).catch(() => {});
    }
  }

  downloads.onCreated.addListener((item) => {
    offer(item);
  });

  return {
    async downloadInBrowser(url) {
      if (!isWebLink(url)) return;
      handedBack.set(sameLink(url), now());
      await downloads.download({ url }).catch(() => handedBack.delete(sameLink(url)));
    },
  };
}
