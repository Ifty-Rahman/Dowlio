export const CATCH_TIMEOUT = 5000;

function isWebLink(link) {
  return /^https?:/i.test(link ?? "");
}

function baseName(path) {
  return path.split(/[\\/]/).pop();
}

export function startCatching({ chrome, link, navigator }) {
  const downloads = chrome.downloads;
  const waitingForName = new Map();

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
    if (!isWebLink(item.url) || !isWebLink(source)) return;
    if (item.incognito || item.byExtensionId === chrome.runtime.id || !link.isConnected()) return;
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
}
