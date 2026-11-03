export const TOAST_ID = "dowlio-connect-toast";
export const TOAST_SHOWN_FOR = 6000;

export function showToast(title, message, id = "dowlio-connect-toast", shownFor = 6000) {
  document.getElementById(id)?.remove();
  const host = document.createElement("div");
  host.id = id;
  host.style.cssText = "all: initial; position: fixed; top: 16px; right: 16px; z-index: 2147483647;";
  const root = host.attachShadow({ mode: "closed" });
  const style = document.createElement("style");
  style.textContent = `
    .toast { box-sizing: border-box; width: 300px; padding: 12px 14px; border-radius: 12px; cursor: default;
      font: 13px/1.35 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #1d1d1f;
      background: rgba(246, 246, 246, 0.94); border: 0.5px solid rgba(0, 0, 0, 0.12);
      box-shadow: 0 8px 28px rgba(0, 0, 0, 0.22); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
      animation: drop 180ms ease-out; }
    .title { font-weight: 600; margin: 0 0 2px; }
    .message { margin: 0; color: #515154; }
    .from { margin: 0 0 6px; font-size: 11px; color: #86868b; }
    @keyframes drop { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: none; } }
    @media (prefers-color-scheme: dark) {
      .toast { color: #f5f5f7; background: rgba(40, 40, 42, 0.94); border-color: rgba(255, 255, 255, 0.14); }
      .message { color: #c7c7cc; }
    }
    @media (prefers-reduced-motion: reduce) { .toast { animation: none; } }
  `;
  const toast = document.createElement("div");
  toast.className = "toast";
  toast.setAttribute("role", "status");
  for (const [className, text] of [["from", "Dowlio Connect"], ["title", title], ["message", message]]) {
    const line = document.createElement("p");
    line.className = className;
    line.textContent = text;
    toast.append(line);
  }
  root.append(style, toast);
  let timer = setTimeout(() => host.remove(), shownFor);
  toast.addEventListener("mouseenter", () => clearTimeout(timer));
  toast.addEventListener("mouseleave", () => {
    timer = setTimeout(() => host.remove(), 1500);
  });
  toast.addEventListener("click", () => host.remove());
  (document.body ?? document.documentElement).append(host);
}
