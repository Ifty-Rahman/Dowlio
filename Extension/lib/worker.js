import { browserName } from "./browser.js";
import { startCatching } from "./catching.js";
import { startSending } from "./sending.js";
import { startCookies } from "./cookies.js";
import { startWatching } from "./watching.js";
import { clientProof, keyOf, nonce, sameText, serverProof } from "./proof.js";

export { browserName };

export const PORTS = [51517, 51518, 51519, 51520];
export const RETRY_DELAY = 5000;
export const PING_INTERVAL = 20000;
export const WAKE_ALARM = "dowlio-connect";
const PROTOCOL = 1;
const GREY = "#8E8E93";
const BEFORE_TRUST = new Set(["pair.codeNeeded", "pair.codeWrong", "pair.approved", "pair.refused", "hello.challenge", "hello.ok", "hello.rejected", "ping"]);

function catchingFrom(value) {
  const list = (sites) => (Array.isArray(sites) ? sites.filter((site) => typeof site === "string").map((site) => site.toLowerCase()) : []);
  return {
    catches: value?.catches !== false,
    neverCatch: list(value?.neverCatch),
  };
}

export function startWorker({ chrome, WebSocket, timers, navigator, ports = PORTS, now = Date.now }) {
  const storage = chrome.storage.local;
  const version = chrome.runtime.getManifest().version;
  let socket = null;
  let portIndex = 0;
  let pingTimer = null;
  let retryTimer = null;
  let reconnectAtOnce = false;
  let requests = 0;
  let connected = false;
  let handshake = null;
  let codeSent = false;
  let preferences = { catches: true, neverCatch: [] };
  let preferencesLoaded = false;
  storage.remove("code");
  const loaded = storage.get("catching").then(({ catching }) => {
    if (catching) preferences = catchingFrom(catching);
    preferencesLoaded = true;
  });
  const pending = new Map();

  async function setStatus(status) {
    await storage.set({ status });
    const connected = status === "connected";
    await chrome.action.setBadgeText({ text: connected ? "" : "off" });
    if (!connected) await chrome.action.setBadgeBackgroundColor({ color: GREY });
  }

  function send(type, fields = {}) {
    if (socket?.readyState !== WebSocket.OPEN) return null;
    requests += 1;
    const requestId = `${type}-${requests}`;
    socket.send(JSON.stringify({ v: PROTOCOL, type, requestId, ...fields }));
    return requestId;
  }

  function reply(type, requestId, fields = {}) {
    if (socket?.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({ v: PROTOCOL, type, requestId, ...fields }));
  }

  function request(type, fields, timeout) {
    return new Promise((resolve) => {
      const requestId = send(type, fields);
      if (requestId === null) return resolve(null);
      const timer = timers.setTimeout(() => settle(requestId, null), timeout);
      pending.set(requestId, { resolve, timer });
    });
  }

  function settle(requestId, reply) {
    const waiting = pending.get(requestId);
    if (!waiting) return false;
    pending.delete(requestId);
    timers.clearTimeout(waiting.timer);
    waiting.resolve(reply);
    return true;
  }

  function settleAll() {
    for (const requestId of [...pending.keys()]) settle(requestId, null);
  }

  async function askToPair() {
    codeSent = false;
    await storage.remove("pairingError");
    await setStatus("pairing");
    send("pair.request", { browser: browserName(navigator), version, extensionId: chrome.runtime.id });
  }

  async function sayHello(token) {
    const current = { token, nonce: nonce(), proven: false };
    handshake = current;
    const key = await keyOf(token);
    if (handshake === current) send("hello", { key, nonce: current.nonce, version });
  }

  async function introduce() {
    const { token, status, stale } = await storage.get(["token", "status", "stale"]);
    if (token && !stale) {
      await sayHello(token);
    } else if (status === "denied") {
      await setStatus("denied");
    } else {
      await askToPair();
    }
  }

  async function handle(message) {
    if (!connected && !BEFORE_TRUST.has(message.type)) return;
    if (connected && message.requestId && settle(message.requestId, message)) return;
    switch (message.type) {
      case "pair.codeNeeded":
        await storage.remove("pairingError");
        await setStatus("pairing");
        break;
      case "pair.codeWrong":
        await storage.set({ pairingError: { left: typeof message.left === "number" ? message.left : 0 } });
        break;
      case "pair.approved":
        if (!codeSent || typeof message.token !== "string") break;
        codeSent = false;
        await storage.set({ token: message.token });
        await storage.remove(["stale", "pairingError"]);
        await sayHello(message.token);
        break;
      case "pair.refused":
        codeSent = false;
        await storage.remove("pairingError");
        if (message.reason === "denied" || message.reason === "timeout") {
          await setStatus("denied");
        } else {
          timers.setTimeout(() => introduce(), RETRY_DELAY);
        }
        break;
      case "hello.challenge": {
        const current = handshake;
        if (!current || current.proven || typeof message.nonce !== "string") break;
        const expected = await serverProof(current.token, current.nonce, message.nonce);
        if (!sameText(expected, message.proof)) {
          handshake = null;
          socket?.close();
          break;
        }
        current.proven = true;
        send("hello.proof", { proof: await clientProof(current.token, current.nonce, message.nonce) });
        break;
      }
      case "hello.ok":
        if (!handshake?.proven) break;
        handshake = null;
        connected = true;
        settleWaiters(true);
        await setStatus("connected");
        break;
      case "hello.rejected":
        if (handshake?.proven) break;
        handshake = null;
        await storage.set({ stale: true });
        reconnectAtOnce = true;
        break;
      case "ping":
        if (typeof message.requestId === "string" && socket?.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ v: PROTOCOL, type: "pong", requestId: message.requestId }));
        }
        break;
      case "extension.reload":
        chrome.runtime.reload();
        break;
      case "settings.update":
        await loaded;
        preferences = catchingFrom(message);
        await storage.set({ catching: preferences });
        break;
      case "browser.download":
        await catching.downloadInBrowser(message.url, typeof message.reason === "string" ? message.reason : undefined);
        break;
      case "page.scan":
        if (typeof message.requestId === "string") await sending.scanFront(message.requestId);
        break;
      case "site.signIn":
        if (typeof message.requestId === "string") {
          const found = /^https?:/i.test(message.url ?? "") ? await cookies.cookiesFor(message.url) : undefined;
          reply("site.signIn", message.requestId, { cookies: found ?? [], userAgent: navigator?.userAgent });
        }
        break;
    }
  }

  function startPing() {
    stopPing();
    pingTimer = timers.setInterval(() => send("ping"), PING_INTERVAL);
  }

  function stopPing() {
    if (pingTimer !== null) timers.clearInterval(pingTimer);
    pingTimer = null;
  }

  function connect() {
    if (retryTimer !== null) timers.clearTimeout(retryTimer);
    retryTimer = null;
    const current = new WebSocket(`ws://127.0.0.1:${ports[portIndex]}`);
    let opened = false;
    socket = current;
    current.onopen = () => {
      opened = true;
      startPing();
      introduce();
    };
    current.onmessage = (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      handle(message);
    };
    current.onclose = () => {
      if (socket !== current) return;
      socket = null;
      connected = false;
      handshake = null;
      codeSent = false;
      stopPing();
      settleAll();
      if (!opened && portIndex < ports.length - 1) {
        portIndex += 1;
        connect();
        return;
      }
      portIndex = 0;
      if (reconnectAtOnce) {
        reconnectAtOnce = false;
        connect();
        return;
      }
      setStatus("disconnected");
      retryTimer = timers.setTimeout(connect, RETRY_DELAY);
      settleWaiters(false);
    };
  }

  function reconnectIfAway() {
    if (socket !== null) return;
    portIndex = 0;
    connect();
  }

  chrome.runtime.onStartup.addListener(reconnectIfAway);
  chrome.runtime.onInstalled.addListener(reconnectIfAway);
  chrome.alarms.create(WAKE_ALARM, { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === WAKE_ALARM) reconnectIfAway();
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "settings.change") {
      if (connected) send("settings.change", { catches: message.catches, neverCatchSite: message.neverCatchSite });
      return;
    }
    if (message?.type === "pair.code") {
      if (socket?.readyState === WebSocket.OPEN && !connected && /^\d{6}$/.test(message.code ?? "")) {
        codeSent = true;
        send("pair.code", { code: message.code });
      }
      return;
    }
    if (message?.type !== "pair.retry") return;
    storage.set({ status: "pairing" }).then(() => {
      if (socket?.readyState === WebSocket.OPEN && !connected) askToPair();
    });
  });

  const isConnected = () => connected && socket?.readyState === WebSocket.OPEN;
  const connectionWaiters = new Set();

  function settleWaiters(result) {
    for (const waiter of [...connectionWaiters]) waiter(result);
  }

  function whenConnected(timeout) {
    if (isConnected()) return Promise.resolve(true);
    if (socket === null && retryTimer !== null) return Promise.resolve(false);
    return new Promise((resolve) => {
      const timer = timers.setTimeout(() => finish(false), timeout);
      function finish(result) {
        timers.clearTimeout(timer);
        connectionWaiters.delete(finish);
        resolve(result);
      }
      connectionWaiters.add(finish);
    });
  }
  const cookies = startCookies({ chrome });
  const connection = {
    isConnected,
    whenConnected,
    request,
    reply,
    release: (requestId) => send("catch.released", { requestId }),
    preferences: () => loaded.then(() => preferences),
    preferencesNow: () => (preferencesLoaded ? preferences : null),
    cookiesFor: (url) => cookies.cookiesFor(url),
  };
  const catching = startCatching({ chrome, navigator, now, link: connection });

  const watching = startWatching({ chrome });
  const sending = startSending({ chrome, navigator, link: connection, watching, timers, now });

  connect();
}
