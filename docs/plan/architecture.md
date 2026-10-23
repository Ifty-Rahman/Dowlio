# Architecture

This file fixes the technology and the methods for the whole app. A phase file may add detail, but it shouldn't contradict this one. Change a decision here first, then update the phases.

## Decisions at a glance

| Area | Choice |
|---|---|
| Language | Swift 6 with strict concurrency |
| Interface | SwiftUI for views. AppKit for the menu bar item, popovers and window control |
| Minimum macOS | macOS 14 Sonoma |
| Project | XcodeGen `project.yml` generates the Xcode project. Logic lives in a local Swift package |
| HTTP | `URLSession`, one session per connection so each segment gets its own TCP connection |
| Plain HTTP | Allowed. App Transport Security is off app-wide and plain-HTTP downloads show "Not secure" (ADR 0003) |
| Storage | SQLite through GRDB for history and settings that need queries. `UserDefaults` for simple preferences. Keychain for secrets |
| Browser extension | Manifest V3 extension in plain JavaScript for Chrome, Arc, Brave and Edge |
| App and extension link | An authenticated WebSocket on `127.0.0.1`, served by the app with Network.framework. No native messaging host |
| Global shortcut | The KeyboardShortcuts package, which uses the Carbon hot-key API and needs no Accessibility permission |
| Page URL from the front browser | Apple Events, after the macOS Automation prompt |
| Site support | yt-dlp, downloaded only from the official GitHub releases of `yt-dlp/yt-dlp` and checked against its published SHA-256 sums |
| Merging and remuxing | AVFoundation where it can do the job. An LGPL-only `ffmpeg` helper for the rest |
| Updates | Sparkle 2 with an EdDSA-signed appcast hosted on GitHub Releases |
| Signing for GitHub | A self-signed code-signing certificate with a stable identity. No Apple Developer ID |
| Distribution | DMG and ZIP on GitHub Releases |

## Repository layout

```
Dowlio/
├── project.yml                 XcodeGen definition of the app target
├── App/                        SwiftUI and AppKit code, assets, Info.plist
├── Packages/DowlioKit/         Swift package with all logic
│   ├── Sources/
│   │   ├── DowlioCore/         Models shared by every module: Download, Segment, errors
│   │   ├── DowlioEngine/       Segmented HTTP engine, file writer, retry, scheduler
│   │   ├── DowlioStore/        GRDB database, migrations, history queries
│   │   ├── DowlioBridge/       Browser link server, pairing, message types
│   │   ├── DowlioMedia/        Page analyser, HLS, yt-dlp and ffmpeg adapters
│   │   └── dowlio-cli/         Command-line tool for testing the engine
│   └── Tests/                  Unit tests and a local fault-injecting test server
├── Extension/                  Browser extension source, plain JavaScript
├── scripts/                    build, sign, package, release, appcast
└── docs/
```

The app target holds views and wiring only. Every rule worth testing lives in `DowlioKit`, where `swift test` runs it without launching the app.

## Process model

Dowlio is one app process. It has no helper processes of its own. It starts two kinds of child process when needed: `yt-dlp` for site extraction, and `ffmpeg` for merging. It never runs a shell. It passes arguments as an array, clears the environment except `PATH` and `HOME`, and kills children that run past a timeout.

Downloads keep running while every window is closed. The app stays alive in the menu bar. Quitting with active downloads asks first.

## The download engine

The engine is an actor, `DownloadEngine`. Each download is a `Download`, in the sense of `GLOSSARY.md`. The method follows RFC 9110 range requests.

1. Probe. Send `GET` with `Range: bytes=0-0` and `Accept-Encoding: identity`. Don't use `HEAD`, because some servers answer it differently. A `206` with `Content-Range: bytes 0-0/N` means the server supports ranges and the file is N bytes. A `200` means one connection only, so keep reading that response as the download.
2. Identity. Record the original URL, the final URL after redirects, a strong `ETag` or the `Last-Modified` date, the content type, and the file name from `Content-Disposition`.
3. Plan. The segment count is the smallest of these values: the user's setting (default 8, maximum 16), the host's learned limit, and the file size divided by 1 MiB.
4. Ramp up. Open the first connection. Open the others once the first one returns bytes. This avoids hammering a server that refuses ranges.
5. Request. Each segment sends `Range` and `If-Range` with the validator. A `200` reply to a ranged request means the file changed on the server. The engine then stops, discards the segments and starts again.
6. Validate. Every `206` must carry a `Content-Range` whose start, end and total match the request exactly. The engine rejects a `Content-Encoding` on ranged replies and rejects `multipart/byteranges`.
7. Work stealing. When a connection finishes its range, it takes the second half of the largest remaining range, if both halves stay above 1 MiB. No slow tail is left at the end.
8. Retry. Each segment retries up to 5 times with exponential backoff and jitter, and honours `Retry-After`. While it waits, the download is Retrying. When a segment runs out of retries, the download becomes Failed. Its partial file stays, and Retry continues it. Dowlio never retries forever. Replies `429`, `503` and connection resets lower the host's connection limit. The engine remembers that limit per host.
9. Resume. A resumed download requests the original URL again and follows its redirects, because signed final URLs expire. If the original URL now fails, for example because it was a one-time link, it tries the saved final URL. It keeps the downloaded segments only if the validator still matches. Otherwise it starts over.
10. Fall back. A `200`, a malformed `206`, a validator mismatch or repeated refusals switch the job to one connection.

Why one `URLSession` per connection: one session pools connections and multiplexes HTTP/2 requests onto a single TCP connection. Separate sessions open separate connections, which is the point of segmenting. `httpMaximumConnectionsPerHost` is raised above its default of 6 for the single-session fallback. Phase 2 measures this before relying on it.

### Files on disk

A download in progress lives in a package next to its destination: `name.ext.dowlio`. The package holds:

- `data`, one file that segments write into at their own offsets with `pwrite`. When the size is known, Dowlio reserves the full size on disk before the first byte arrives, so a download that can't fit fails at once with "Not enough space" instead of near the end.
- `manifest.json`, with a format version, the original and final URLs, the validator, total size, the destination file name, the referrer and user agent, and each segment's `start`, `end` and `received`. It never holds cookies. The engine writes it atomically about once a second and on pause.

The manifest holds everything needed to resume, so a partial file is self-contained. Dowlio registers `.dowlio` as its own file type with its own icon. Double-clicking one opens Dowlio, which shows that download, or adds and resumes it if Dowlio has no record of it.

If the server can't resume, pausing or quitting throws the downloaded bytes away. Dowlio asks first: "This server can't resume. Pausing starts it over from the beginning."

Finalising checks that the segments cover every byte from 0 to N, flushes the file, moves `data` to the destination with an atomic rename, and deletes the package. It never overwrites a file. Name conflicts follow the user's setting, and the default is "Keep both", which adds " 2", " 3" and so on. The finished file gets the `com.apple.quarantine` attribute with Dowlio as the agent, the same as a file a browser downloads. Cancel asks first ("Cancel this download? The 1.2 GB downloaded so far will be deleted."), then deletes the package and removes the download from the list. Dowlio keeps no record of cancelled downloads.

If the partial file disappears, for example because the user deleted it in Finder, the download starts over from the beginning the next time it runs. It doesn't become Failed.

## Storage

- `~/Library/Application Support/Dowlio/Dowlio.sqlite`, through GRDB. Tables for downloads, host connection limits and browser pairings. Migrations run at launch.
- `UserDefaults` for preferences shown in Settings.
- Keychain for browser pairing tokens and any site credentials.
- `~/Library/Application Support/Dowlio/Tools/` for yt-dlp and ffmpeg, each with a recorded SHA-256.
- `~/Library/Application Support/Dowlio/Browser Extension/` for the unpacked extension the user loads into each browser.

Dowlio stores a download's source URL, file name, size, dates and state. It doesn't store page titles, POST bodies, cookies or request headers. For duplicate checks it stores a SHA-256 hash of the normalised page URL instead of the page URL itself. History can be cleared from Settings.

## The browser link

Flow's extension used native messaging and failed because the host registration pointed at an app path that no longer existed (research §8.5). Dowlio drops native messaging. The app runs a small WebSocket server, and the extension connects to it. Nothing depends on where the app is installed or on the extension's ID.

How it works:

1. The app listens on `127.0.0.1` only, on port 51517. If that port is taken, it tries 51518 to 51520. The extension tries the same four ports in order. Binding to loopback only means macOS shows no firewall prompt.
2. The app accepts a connection only if the WebSocket upgrade request has an `Origin` header that starts with `chrome-extension://`. A web page can't send that header, so websites can't reach the app.
3. Pairing. A new extension has no token. It sends `pair.request` with a four-digit code that it also shows in its popup. Dowlio shows "A browser extension wants to connect. Code 4821. Allow?" When the user allows it, the app sends back a random 256-bit token. The extension keeps the token in `chrome.storage.local`. The app keeps a hash of it in the Keychain. Every later connection starts with `hello` and the token, or the app closes it.
4. Keep-alive. The extension sends a ping every 20 seconds. Since Chrome 116, WebSocket traffic keeps an MV3 service worker alive.
5. If the app isn't running, the extension can't connect. It then leaves every download to the browser and shows a grey toolbar badge. It retries every 5 seconds. A failed link never loses a download.
6. Messages are JSON with a version number, a `type` and a `requestId`. Both sides reject anything above 256 KB and anything that fails validation.

The extension asks for these permissions at install: `downloads`, `storage`, `contextMenus`, `activeTab`, `scripting`, `notifications`. It has no content scripts, no `tabs`, no `cookies`, no `webRequest` and no host permissions at install. Sharing sign-in with Dowlio is an optional permission. The extension requests it per site, only after a user click (phase 4).

Phase 4 starts with a one-day spike. The spike checks that the current Chrome and Arc let an extension service worker open `ws://127.0.0.1` without a Local Network Access prompt. If they don't, the spike result decides the fix before any other phase 4 work.

## Send to Dowlio

Two triggers lead to the same page analyser:

- The Dowlio shortcut, default ⌥⇧D, is a global hot key that the app owns. The user can change it in onboarding and in Settings. The app reads the front browser's current URL with Apple Events. This works in Safari, Chrome, Arc, Brave and Edge. macOS asks once per browser for Automation permission, and onboarding explains that prompt before it appears.
- The extension's toolbar button and context menu. These are user gestures, so Chrome grants `activeTab`. The extension then runs a one-time scan script in the page. The script collects `<video>`, `<audio>` and `<source>` URLs, file links, Open Graph tags and media requests the page has already made. That's the richer path, because it sees what the signed-in page loaded.

The analyser then runs these steps, in order, and stops at the first that finds something. Phases 5 and 6 build them.

1. Is the URL itself a file? Probe it.
2. Media and file links from the extension scan, if one came with the request.
3. The page's HTML, fetched without cookies: Open Graph video, JSON-LD `VideoObject`, `<video>` tags, file links.
4. yt-dlp, for sites it supports.
5. Look Again, when the user asks. Dowlio loads the page in a hidden `WKWebView` with a non-persistent data store, mutes it, presses play and records media requests for up to 10 seconds.

The result is a list of versions (resolution, codec, size or estimate) shown in the Send panel.

## Media

- Direct media files go through the segmented engine.
- HLS. Dowlio parses playlists itself, following RFC 8216, picks the variant, downloads segments in parallel through the engine's scheduler and decrypts `AES-128` segments with CommonCrypto. It refuses `SAMPLE-AES` and any FairPlay, Widevine or PlayReady key with a clear "This video is protected" message.
- yt-dlp handles site-specific extraction. Dowlio runs `yt-dlp --dump-single-json` to list formats. Plain HTTPS formats then download through Dowlio's engine. Formats that need yt-dlp's own protocol handling download through yt-dlp, with progress read from `--progress-template` output.
- Merging. AVFoundation remuxes H.264, HEVC and AAC into MP4 without re-encoding. The `ffmpeg` helper handles VP9, AV1, Opus, WebM and MKV, and yt-dlp's own merges. The helper is built from the official FFmpeg source with only LGPL code, in Dowlio's CI. It's a separate executable that the app runs, not a library linked into the app.

### yt-dlp source rule

Dowlio only ever downloads yt-dlp from `https://github.com/yt-dlp/yt-dlp/releases`. It reads the release with the GitHub API at `api.github.com/repos/yt-dlp/yt-dlp/releases/latest`, downloads the `yt-dlp_macos` asset and the `SHA2-256SUMS` file from the same release, and installs the binary only if the hashes match. Redirects may only lead to GitHub's download hosts. Before each run, Dowlio checks the installed file's hash against the recorded one. It doesn't use a yt-dlp from Homebrew, pip or the user's `PATH`.

## Signing and distribution without a Developer ID

- CI creates and stores a self-signed code-signing certificate named "Dowlio Self Signed" once, as a GitHub Actions secret. Every build uses the same certificate, so macOS keeps Automation and Keychain permissions across updates. Ad-hoc signing would change the identity on every build and reset those permissions.
- Builds use the hardened runtime.
- Gatekeeper blocks the first launch, because the app isn't notarized. The user opens it once from System Settings › Privacy & Security › Open Anyway. The install guide shows this with screenshots (phase 8).
- Sparkle updates are verified with an EdDSA key that's also stored as a CI secret. Updates installed by Sparkle don't trigger Gatekeeper again.
- App Store distribution comes later in phase 9 and needs an Apple Developer account.

## Privacy rules

These hold in every phase.

- No analytics, crash reporting service, ads or tracking SDK.
- Logs use `os.Logger` and mark URLs, paths and file names as private. No log line contains a full URL.
- Finished files get the quarantine flag with Dowlio as the agent and the download's source URL as the origin, the same as a browser download. macOS keeps the URL in its own per-user quarantine log, not in the file. The owner chose this on 2026-10-23, so macOS can show where a file came from.
- Cookies never touch disk. When the user shares sign-in for a site, the cookies stay in memory for that download only.
- Dowlio talks only to the sites the user downloads from, GitHub (yt-dlp and Dowlio updates), and the local browser link.

## Testing

- `swift test` runs unit tests for every module.
- A test server in `Tests/Support`, built on Network.framework, serves files with or without range support. It can throttle, drop connections, change the file mid-download, send wrong `Content-Range` values and return `429` with `Retry-After`. Engine tests run against it.
- The extension's logic lives in plain ES modules that Node's built-in test runner tests without a browser.
- Each phase lists manual checks for anything that needs a real browser or a real Mac session.
