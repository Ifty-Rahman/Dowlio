import { startCatching } from "./catching.js";

export const PORTS = [51517, 51518, 51519, 51520];
export const RETRY_DELAY = 5000;
export const PING_INTERVAL = 20000;
export const WAKE_ALARM = "dowlio-connect";
const PROTOCOL = 1;
const GREY = "#8E8E93";

export function browserName(navigator) {
  const brands = navigator?.userAgentData?.brands ?? [];
  const named = brands.map((entry) => entry.brand).find((brand) => !/not.?a.?brand|chromium/i.test(brand));
  return named ?? "Chromium";
}

export function startWorker({ chrome, WebSocket, timers, navigator, random = Math.random, ports = PORTS, now = Date.now }) {
  const storage = chrome.storage.local;
  const version = chrome.runtime.getManifest().version;
  let socket = null;
  let portIndex = 0;
  let pingTimer = null;
  let retryTimer = null;
  let reconnectAtOnce = false;
  let requests = 0;
  let connected = false;
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

  async function pairingCode() {
    const { code } = await storage.get("code");
    if (code) return code;
    const fresh = String(Math.floor(random() * 10000)).padStart(4, "0");
    await storage.set({ code: fresh });
    return fresh;
  }

  async function askToPair() {
    const code = await pairingCode();
    await setStatus("pairing");
    send("pair.request", { code, browser: browserName(navigator), version, extensionId: chrome.runtime.id });
  }

  async function introduce() {
    const { token, status } = await storage.get(["token", "status"]);
    if (token) {
      send("hello", { token, version });
    } else if (status === "denied") {
      await setStatus("denied");
    } else {
      await askToPair();
    }
  }

  async function handle(message) {
    if (message.requestId && settle(message.requestId, message)) return;
    switch (message.type) {
      case "pair.approved":
        await storage.set({ token: message.token });
        await storage.remove("code");
        send("hello", { token: message.token, version });
        break;
      case "pair.refused":
        if (message.reason === "denied") {
          await setStatus("denied");
        } else {
          timers.setTimeout(() => introduce(), RETRY_DELAY);
        }
        break;
      case "hello.ok":
        connected = true;
        await storage.remove("code");
        await setStatus("connected");
        break;
      case "hello.rejected":
        await storage.remove("token");
        reconnectAtOnce = true;
        break;
      case "browser.download":
        await catching.downloadInBrowser(message.url);
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
    };
  }

  function reconnectIfAway() {
    if (socket !== null) return;
    portIndex = 0;
    connect();
  }

  chrome.runtime.onStartup.addListener(reconnectIfAway);
  chrome.alarms.create(WAKE_ALARM, { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === WAKE_ALARM) reconnectIfAway();
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "pair.retry") return;
    storage.remove("code").then(() => storage.set({ status: "pairing" })).then(() => {
      if (socket?.readyState === WebSocket.OPEN) askToPair();
    });
  });

  const catching = startCatching({
    chrome,
    navigator,
    now,
    link: { isConnected: () => connected && socket?.readyState === WebSocket.OPEN, request },
  });

  connect();
}
