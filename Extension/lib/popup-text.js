export function popupText(status) {
  switch (status) {
    case "connected":
      return { headline: "Connected to Dowlio", detail: "Downloads from this browser can finish in Dowlio." };
    case "pairing":
      return {
        headline: "Allow this browser in Dowlio",
        detail: "Dowlio is asking whether to connect. Allow it only if Dowlio shows this code.",
        showsCode: true,
      };
    case "denied":
      return { headline: "Dowlio didn't allow this browser", detail: "Ask again to show the request in Dowlio.", showsRetry: true };
    default:
      return { headline: "Dowlio isn't running", detail: "Open Dowlio, and Dowlio Connect connects on its own." };
  }
}
