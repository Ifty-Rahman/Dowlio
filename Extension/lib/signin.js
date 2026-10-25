const WEB_ORIGIN = /^https?:\/\/[^/:]+\/\*$/;

export function originOf(url) {
  try {
    const parsed = new URL(url);
    return /^https?:$/.test(parsed.protocol) ? `${parsed.protocol}//${parsed.hostname}` : null;
  } catch {
    return null;
  }
}

export function allowedOriginsIn({ origins = [] }) {
  return origins.filter((pattern) => WEB_ORIGIN.test(pattern)).map((pattern) => pattern.slice(0, -2)).sort();
}

export function startSignIn({ chrome, connection }) {
  async function allowedOrigins() {
    return allowedOriginsIn(await chrome.permissions.getAll());
  }

  async function cookiesFor(url) {
    const origin = originOf(url);
    if (!origin) return undefined;
    const allowed = await chrome.permissions.contains({ permissions: ["cookies"], origins: [`${origin}/*`] });
    if (!allowed) return undefined;
    const cookies = await chrome.cookies.getAll({ url }).catch(() => []);
    return cookies.map(({ name, value }) => ({ name, value }));
  }

  async function reportSites() {
    if (connection.isConnected()) connection.send("signin.sites", { origins: await allowedOrigins() });
  }

  function askForSignIn(url) {
    let host = url;
    try {
      host = new URL(url).hostname;
    } catch {}
    chrome.notifications.create(`signin-${host}`, {
      type: "basic",
      iconUrl: "icons/128.png",
      title: "Dowlio",
      message: `${host} needs your sign-in. Click the Dowlio button to let it use your sign-in for this site.`,
    });
  }

  async function revoke(origin) {
    if (!originOf(origin)) return;
    await chrome.permissions.remove({ origins: [`${originOf(origin)}/*`] });
    if ((await allowedOrigins()).length === 0) await chrome.permissions.remove({ permissions: ["cookies"] });
  }

  chrome.permissions.onAdded.addListener(async ({ origins = [] }) => {
    for (const pattern of origins.filter((entry) => WEB_ORIGIN.test(entry))) {
      const origin = pattern.slice(0, -2);
      const cookies = (await cookiesFor(`${origin}/`)) ?? [];
      if (connection.isConnected()) connection.send("signin.granted", { origin, cookies });
    }
    await reportSites();
  });
  chrome.permissions.onRemoved.addListener(() => reportSites());

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "signin.remove" && typeof message.origin === "string") revoke(message.origin);
  });

  return { cookiesFor, reportSites, askForSignIn, revoke };
}
