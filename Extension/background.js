import { startWorker } from "./lib/worker.js";

startWorker({ chrome, WebSocket, timers: globalThis, navigator });
