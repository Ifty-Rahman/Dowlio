export function flush() {
  return new Promise((resolve) => setImmediate(resolve));
}

export class FakeTimers {
  constructor() {
    this.now = 0;
    this.timers = [];
    this.nextId = 1;
  }

  setTimeout = (callback, delay) => this.add(callback, delay, false);
  setInterval = (callback, delay) => this.add(callback, delay, true);
  clearTimeout = (id) => this.remove(id);
  clearInterval = (id) => this.remove(id);

  add(callback, delay, repeats) {
    const id = this.nextId++;
    this.timers.push({ id, callback, delay, repeats, due: this.now + delay });
    return id;
  }

  remove(id) {
    this.timers = this.timers.filter((timer) => timer.id !== id);
  }

  async advance(ms) {
    const end = this.now + ms;
    for (;;) {
      const next = this.timers.filter((timer) => timer.due <= end).sort((a, b) => a.due - b.due)[0];
      if (!next) break;
      this.now = next.due;
      if (next.repeats) next.due += next.delay;
      else this.remove(next.id);
      next.callback();
      await flush();
    }
    this.now = end;
    await flush();
  }
}

export function fakeChrome({ stored = {}, id = "abcdefghijklmnopabcdefghijklmnop", version = "0.2.0" } = {}) {
  const data = { ...stored };
  const listeners = [];
  const alarmListeners = [];
  const createdListeners = [];
  const changedListeners = [];
  const chrome = {
    downloads: {
      calls: [],
      failing: new Set(),
      whilePausing: null,
      async record(name, id) {
        chrome.downloads.calls.push([name, id]);
        if (chrome.downloads.failing.has(name)) throw new Error(`${name} failed`);
      },
      async pause(id) {
        const during = chrome.downloads.whilePausing;
        chrome.downloads.whilePausing = null;
        if (during) await during();
        await chrome.downloads.record("pause", id);
      },
      async resume(id) {
        await chrome.downloads.record("resume", id);
      },
      async cancel(id) {
        await chrome.downloads.record("cancel", id);
      },
      async erase(query) {
        await chrome.downloads.record("erase", query.id);
      },
      nextId: 100,
      async download(options) {
        await chrome.downloads.record("download", options.url);
        const id = chrome.downloads.nextId++;
        createdListeners.forEach((listener) =>
          listener({ id, url: options.url, finalUrl: options.url, filename: "", incognito: false, state: "in_progress" }),
        );
        return id;
      },
      onCreated: { addListener: (listener) => createdListeners.push(listener) },
      onChanged: { addListener: (listener) => changedListeners.push(listener) },
      async create(item) {
        createdListeners.forEach((listener) => listener(item));
        for (let turn = 0; turn < 3; turn += 1) await flush();
      },
      async change(delta) {
        changedListeners.forEach((listener) => listener(delta));
        await flush();
      },
    },
    alarms: {
      created: {},
      create(name, info) {
        chrome.alarms.created[name] = info;
      },
      onAlarm: { addListener: (listener) => alarmListeners.push(listener) },
      fire: (name) => alarmListeners.forEach((listener) => listener({ name })),
    },
    badge: { text: undefined, color: undefined },
    contextMenus: {
      items: [],
      clickListeners: [],
      removeAll(callback) {
        chrome.contextMenus.items = [];
        callback?.();
      },
      create(item) {
        chrome.contextMenus.items.push(item);
      },
      onClicked: { addListener: (listener) => chrome.contextMenus.clickListeners.push(listener) },
      async click(info, tab) {
        chrome.contextMenus.clickListeners.forEach((listener) => listener(info, tab));
        for (let turn = 0; turn < 3; turn += 1) await flush();
      },
    },
    permissions: {
      granted: { permissions: new Set(), origins: new Set() },
      addedListeners: [],
      removedListeners: [],
      async contains({ permissions = [], origins = [] }) {
        const granted = chrome.permissions.granted;
        return permissions.every((name) => granted.permissions.has(name)) && origins.every((origin) => granted.origins.has(origin));
      },
      async getAll() {
        return { permissions: [...chrome.permissions.granted.permissions], origins: [...chrome.permissions.granted.origins] };
      },
      async allow({ permissions = [], origins = [] }) {
        permissions.forEach((name) => chrome.permissions.granted.permissions.add(name));
        origins.forEach((origin) => chrome.permissions.granted.origins.add(origin));
        chrome.permissions.addedListeners.forEach((listener) => listener({ permissions, origins }));
        for (let turn = 0; turn < 3; turn += 1) await flush();
      },
      async remove({ permissions = [], origins = [] }) {
        permissions.forEach((name) => chrome.permissions.granted.permissions.delete(name));
        origins.forEach((origin) => chrome.permissions.granted.origins.delete(origin));
        chrome.permissions.removedListeners.forEach((listener) => listener({ permissions, origins }));
        return true;
      },
      onAdded: { addListener: (listener) => chrome.permissions.addedListeners.push(listener) },
      onRemoved: { addListener: (listener) => chrome.permissions.removedListeners.push(listener) },
    },
    cookies: {
      jar: {},
      async getAll({ url }) {
        if (!chrome.permissions.granted.permissions.has("cookies")) throw new Error("no cookies permission");
        return chrome.cookies.jar[new URL(url).origin] ?? [];
      },
    },
    notifications: {
      shown: [],
      create(id, options) {
        chrome.notifications.shown.push(options ?? id);
      },
    },
    storage: {
      local: {
        data,
        async get(keys) {
          const list = keys == null ? Object.keys(data) : [keys].flat();
          return Object.fromEntries(list.filter((key) => key in data).map((key) => [key, data[key]]));
        },
        async set(values) {
          Object.assign(data, values);
        },
        async remove(keys) {
          for (const key of [keys].flat()) delete data[key];
        },
      },
    },
    action: {
      async setBadgeText({ text }) {
        chrome.badge.text = text;
      },
      async setBadgeBackgroundColor({ color }) {
        chrome.badge.color = color;
      },
    },
    runtime: {
      id,
      getManifest: () => ({ version }),
      onMessage: { addListener: (listener) => listeners.push(listener) },
      onStartup: { addListener: () => {} },
      sendMessage: (message) => listeners.forEach((listener) => listener(message)),
    },
  };
  return chrome;
}

export function fakeSockets() {
  const sockets = [];
  class FakeWebSocket {
    static OPEN = 1;

    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.sent = [];
      sockets.push(this);
    }

    send(text) {
      this.sent.push(JSON.parse(text));
    }

    close() {
      this.fail();
    }

    async accept() {
      this.readyState = 1;
      this.onopen?.();
      await flush();
    }

    async reply(message) {
      this.onmessage?.({ data: JSON.stringify({ v: 1, ...message }) });
      await flush();
    }

    async fail() {
      if (this.readyState === 3) return;
      this.readyState = 3;
      this.onclose?.({ code: 1006 });
      await flush();
    }
  }
  return { FakeWebSocket, sockets, last: () => sockets[sockets.length - 1] };
}

export const navigatorLike = (brands = [{ brand: "Chromium", version: "156" }, { brand: "Arc", version: "156" }]) => ({
  userAgentData: { brands },
});
