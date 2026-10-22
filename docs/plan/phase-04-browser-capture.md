# Phase 4: Browser capture

## Goal

Downloads the user clicks in Chrome, Arc, Brave or Edge finish in Dowlio. When Dowlio can't take a download, the browser keeps it, so a download is never lost. The link between the app and the extension reports its real state and repairs itself.

## Before you start

Phase 3. Read "The browser link" in architecture.md and research §8.5, which explains why Flow's link failed.

## How it's built

### The app side, `DowlioBridge`

- `BridgeServer` uses `NWListener` with `NWProtocolWebSocket` on `127.0.0.1`, ports 51517 to 51520. Its `setClientRequestHandler` rejects any upgrade whose `Origin` doesn't start with `chrome-extension://`.
- `Pairing` handles `pair.request`. It shows the approval alert with the extension's code, creates the token, and stores a hash of the token in the Keychain with the browser name and extension ID. It allows one pending request at a time and at most 5 requests a minute.
- `BridgeSession` is one authenticated connection. It records the browser name, the extension version and when it was last seen.
- `Messages.swift` defines every message as a `Codable` enum with a version field. Unknown types get an error reply, never a crash.

### The extension, `Extension/`

- Manifest V3. A service worker `background.js`, a popup, an options page, and pure logic modules in `lib/` that Node tests.
- Permissions at install: `downloads`, `storage`, `contextMenus`, `activeTab`, `scripting`, `notifications`.
- Optional permissions: `cookies`, plus optional host permissions `https://*/*` and `http://*/*`. The extension requests them one site at a time.
- No content scripts, no `tabs`, no `webRequest`, nothing drawn on pages.

### Installing the extension, with no store

1. The app ships the extension inside its bundle. Settings › Browsers and onboarding page 3 show each installed Chromium browser. The app finds them by bundle ID: Chrome, Chrome Beta, Arc, Brave, Edge.
2. Add copies the extension to `~/Library/Application Support/Dowlio/Browser Extension/`. That stable path doesn't change when the app moves or updates.
3. Add then opens that browser's extensions page with `NSWorkspace.open(_:withApplicationAt:)` and reveals the folder in Finder. A short guide in the sheet reads: turn on Developer mode, click Load unpacked, choose the Dowlio folder.
4. The extension starts, connects and sends `pair.request`. The user approves the code in Dowlio. The browser row turns to Connected.
5. After a Dowlio update, the app rewrites the folder. On the next `hello`, it sees the old extension version and sends `extension.reload`. The extension calls `chrome.runtime.reload()`, which loads the new files from disk.

### Catching a download

1. `downloads.onCreated` fires. The extension skips the download if any of these hold: catching is off, the site is on the never-catch list, the file is under the size threshold, the URL isn't `http` or `https` (for example `blob:` or `data:`), the download came from Dowlio's own "Download in browser instead", or no app is connected.
2. Otherwise the extension pauses the download and sends `catch.offer` with the URL, final URL, referrer, suggested file name, MIME type and size. If the user shared sign-in for that site, it adds that URL's cookies from `chrome.cookies.getAll({url})`.
3. Dowlio probes the URL, sending the referrer and any cookies, and answers within 5 seconds:
   - `accept`: the extension cancels and erases the browser's download. Dowlio starts it and shows the catch toast.
   - `decline` with a reason: the extension resumes the browser's download. Reasons: `needsSignIn`, `unsupported`, `tooSmall`, `error`.
   - No answer within 5 seconds counts as a decline.
4. Download in Browser Instead, in the toast, makes Dowlio cancel its copy and send `browser.download`. The extension starts the download in the browser and marks it so it isn't caught again.

### Sign-in sharing

When Dowlio declines with `needsSignIn`, the extension shows a notification: "example.com needs your sign-in. Click the Dowlio button to let it use your sign-in for this site." In the popup, the button calls `chrome.permissions.request` for `cookies` and that site's origin. That call needs the user's click. Chrome then shows its own permission prompt. Allowed sites are listed in the popup and in Settings › Browsers, each with Remove. Dowlio keeps cookies in memory for that download only. If the app restarts mid-download, the download waits for "Send it again from the browser".

### Connection status

Each browser row in Settings shows one of these states.

| State | Meaning | What the app offers |
|---|---|---|
| Connected | A `hello` arrived in the last 60 seconds | Test |
| Not connected | Paired before but not seen | "Open the browser" and Test |
| Needs reload | Paired, extension version older than the app | Reload, which sends `extension.reload` |
| Not installed | Never paired | Add |

Test sends `ping` and waits for `pong` within 2 seconds. On failure it names the step that failed: server not listening, port in use by another app, no extension connected, pairing missing.

## Steps

1. Spike, one day. A minimal extension and a minimal `NWListener` WebSocket server. Check that Chrome and Arc connect from the service worker to `ws://127.0.0.1` with no Local Network Access prompt, and that the worker stays alive with a 20-second ping. Write the result in `docs/adr/NNNN-browser-link.md`. If either check fails, decide the fix there before continuing.
2. Build `BridgeServer`, `Pairing`, `BridgeSession` and `Messages.swift`, with tests that connect from a Swift WebSocket client.
3. Build the extension's connection module: port order, reconnect every 5 seconds, ping, pairing, and the token in `chrome.storage.local`.
4. Build catching in the extension and `catch.offer` handling in the app. Write the logic as pure functions in `lib/` and test it with Node.
5. Build the catch toast in the menu bar popover from design.md.
6. Build the popup. It shows connection status, the Catch downloads switch, "Never catch on this site", the shared sign-in list and Open Dowlio. The app stays the source of truth for the switch and the never-catch list, and sends both to the extension.
7. Build Settings › Browsers and onboarding page 3, with Add, live status and Test.
8. Build sign-in sharing.
9. Build the extension update path with `extension.reload`.
10. Release `v0.2.0`.

## Done when

- On a fresh user account, a clean install, Add and approve leaves Arc connected in under two minutes, with no manual file editing.
- Moving `Dowlio.app` to another folder and relaunching keeps the browser connected.
- Clicking a large file link in Arc finishes it in Dowlio. The browser's download disappears and the toast shows.
- With Dowlio quit, the same click downloads normally in Arc.
- A site that needs sign-in falls back to the browser, offers sign-in sharing, and works after the user allows it.
- A web page that opens `new WebSocket("ws://127.0.0.1:51517")` is refused.
- An extension without a token can't send anything except `pair.request`.

## Out of scope

Send Page (phase 5), Firefox and Safari (phase 9 or later), Chrome Web Store publishing.
