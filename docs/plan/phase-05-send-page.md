# Phase 5: Send page

## Goal

The user presses ⌥⇧D, or clicks the Dowlio button in the browser, on a page without a download button. Dowlio finds the files and media on that page and shows them in the Send panel. One click starts the download. This phase handles direct files and plain media files. HLS streams and site extraction come in phase 6.

## Before you start

Phase 4.

## How it's built

### Triggers

- Global shortcut. The KeyboardShortcuts package registers the hot key and provides the recorder view used in onboarding page 4 and Settings › Browsers. On press, `FrontBrowser` reads `NSWorkspace.shared.frontmostApplication`. If it's a supported browser, it reads the current tab's URL with an Apple Event through `NSAppleScript`: `URL of active tab of front window` for Chromium browsers, `URL of current tab of front window` for Safari. The app declares `NSAppleEventsUsageDescription` and the `com.apple.security.automation.apple-events` entitlement. If the front app isn't a browser, or permission was refused, the Send panel offers the link on the clipboard instead.
- Extension button, command and context menu. Clicking the toolbar button, choosing "Send page to Dowlio" or "Download link with Dowlio" in the context menu, or pressing the extension's command shortcut is a user gesture. Chrome grants `activeTab`, and the extension runs `scan.js` once with `chrome.scripting.executeScript`. Then it sends `page.send` with the URL, title and scan results.

### The scan script

`scan.js` runs once in the page and returns a list of candidates. It reads:

- `<video>`, `<audio>` and `<source>` elements and their `src`, skipping `blob:` URLs,
- links whose path ends in a known file extension, and links with a `download` attribute,
- `og:video`, `og:audio` and `twitter:player:stream` meta tags,
- JSON-LD `VideoObject` and `AudioObject` entries,
- `performance.getEntriesByType("resource")` entries that look like media (`.mp4`, `.m4a`, `.webm`, `.mp3`, `.m3u8`, `.mpd`).

It sends no cookies, no page text and no form data.

### The analyser, `PageAnalyzer` in `DowlioMedia`

It runs these steps in order and merges what they find:

1. `FileCheck`. Probe the URL. If it isn't HTML, the page is the file.
2. Scan candidates from the extension, if any.
3. `HTMLReader`. Fetch the page without cookies, parse meta tags, JSON-LD, media elements and file links. Use a small tolerant tag scanner, not a full HTML parser.
4. `LookAgain`, only when the user clicks it. A hidden `WKWebView` with `WKWebsiteDataStore.nonPersistent()` loads the page, muted. An injected script starts the first video and reports media resources through a `WKScriptMessageHandler`. It stops after 10 seconds.

Each candidate is probed for size and type. Steps 2 and 3 can run in parallel, with results streaming into the panel as they arrive.

### The Send panel

The Send panel is an `NSPopover` from the menu bar item, with the seven states in design.md. "Download" starts the selected candidate through the engine. "More options" opens the New Download sheet with the candidate filled in.

### Duplicates

Before showing results, the analyser hashes the normalised page URL and each candidate URL, then looks them up in history. A match shows the Already downloaded state with Show in Finder and Download Again. Normalising lowercases the host, removes the fragment and removes common tracking parameters (`utm_*`, `fbclid`, `gclid`).

## Steps

1. Add KeyboardShortcuts as a Swift package dependency. Build the recorder in Settings › Browsers and onboarding page 4.
2. Build `FrontBrowser` with Apple Events for Safari, Chrome, Arc, Brave and Edge. Handle "permission denied" with a clear next step that opens System Settings › Privacy & Security › Automation.
3. Build `scan.js`, the `page.send` message and the context menu items.
4. Build `PageAnalyzer` with `FileCheck` and `HTMLReader`. Test them on saved HTML fixtures from real page types: a file host page, a news article with an embedded MP4, a podcast page with an MP3, an Open Graph video page.
5. Build the Send panel and its states.
6. Build Look Again.
7. Build duplicate detection.
8. Release `v0.3.0`.

## Done when

- ⌥⇧D on a page with an embedded MP4 in Safari and in Arc shows the video in the panel within 2 seconds. One click downloads it.
- ⌥⇧D on a direct PDF link shows the Page is a file state.
- The extension button on a signed-in page finds media that the cookie-less HTML fetch can't see.
- A page with nothing on it shows Nothing found, and Look Again either finds media or says it found nothing.
- Sending the same page twice shows Already downloaded.
- Denying Automation permission shows the clipboard fallback and how to turn the permission on.

## Out of scope

HLS, DASH, yt-dlp and merging (phase 6).
