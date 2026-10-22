# Design

Dowlio follows the Flow design. The sources are:

- `docs/flow-ui-reference/DESIGN.md`, the token and component system
- `docs/flow-ui-reference/Flow Download Manager UI.pdf`, the 24-page light-mode design
- `docs/flow-ui-reference/screenshots/`, ten dark-mode screenshots of Flow 0.1.2
- `docs/flow-ui-reference/swift/`, reference SwiftUI for the onboarding, segmented bar and menu bar

Treat these as reference, not as code to copy. This file lists what Dowlio keeps and what it changes.

## What stays

- One accent colour. Dowlio Blue is `#2B5FE3` in light mode and `#5285F3` in dark mode. Every other colour is a semantic system colour.
- Text uses macOS text styles, never fixed sizes. Numbers that change use monospaced digits.
- Radii are 12 pt for containers and 8 pt for nested elements. Spacing uses 4, 8, 12, 16, 20 and 24 pt.
- The segmented progress bar is the brand motif. It appears in rows, the menu bar popover, the catch toast, onboarding and the app icon.
- State colours are blue for downloading, grey for paused and queued, orange for retrying, green for completed and red for failed. Colour never carries meaning alone, so each state also has a word and an icon.
- Native chrome. macOS draws windows, sheets, popovers, toolbars and controls. Dowlio draws only the content.
- Plain, sentence-case copy that says what happens, for example "Dowlio paused it, so nothing downloaded so far is lost."
- Motion is short and honours Reduce Motion.

## Main window

From the screenshots, unchanged:

- The sidebar has Library (All Downloads, Downloading, Paused, Queued, Failed, Completed) and Categories (Video, Audio, Documents, Archives, Apps & Disk Images). A footer card shows free disk space.
- The toolbar has a title with an item count and live total speed, then buttons for Clear Completed, New Download, Resume All and Pause All, then Search.
- The empty state shows an inbox icon, "No downloads yet", a hint about ⌘V, drag and drop and ⌥⇧D, and a New Download button.
- Each row has a file-type badge, file name, coloured state word, segmented bar, a detail line ("2.05 GB of 3.21 GB · 8 connections"), speed and time left, and one action button.

Changes:

- Add an inspector on the right, from PDF page 8: big percentage, segment mini-bars, speed, time left, "Resumable", source host, Show in Finder, Copy Link. It's hidden by default and toggled from the toolbar.
- Double-clicking a row opens the detail window from PDF page 10, with the per-connection table and a 60-second speed graph.
- Failed rows show the reason and a single next step, for example "Link expired · Send it again from the browser".

## New Download sheet

From the screenshot, unchanged: Link field (several links, one per line), Save to with Choose…, Connections stepper with "8 to 16 is fastest", Advanced disclosure, Start immediately toggle, Cancel and Download.

Changes:

- After a link is pasted, show the file card from PDF page 9. It has the type badge, an editable name, the size, and a status line: "Checking link…", then "Resumable, splits into segments" in green or "Single connection only" in orange with a one-line reason.
- Advanced holds the referrer and user agent fields. It doesn't offer a cookie field.

## Menu bar

Flow 0.1.2 used a plain menu (Add Link, Open Flow, Send Feedback, Quit). The PDF used a richer popover. Dowlio uses the popover, because the Send panel and the catch toast both need to open from the menu bar icon.

- The popover shows "2 downloading · 1 queued", total speed, a short list of active downloads with thin segmented bars, a Catch browser downloads switch, and Pause All, Add Link… and Open Dowlio.
- A small ⋯ menu inside the popover holds Settings, Report a Problem and Quit Dowlio.
- Report a Problem opens a prefilled GitHub issue. It replaces Flow's email-based Send Feedback.
- While downloading, the menu bar icon shows a thin progress ring. It shows nothing more, to keep the menu bar quiet.

## Send panel

From the PDF, pages 2, 3 and 7. It drops from the menu bar icon and has seven states: Looking, Several items, Already downloaded, The page is a file, Nothing found, Needs sign-in, Started.

Changes:

- The Needs sign-in state explains the actual option: "This site only gives the file to signed-in visitors. Use the Dowlio button in your browser and allow sign-in sharing for this site."
- Nothing found offers Look Again. It says that Look Again opens the page in a hidden window for up to 10 seconds.

## Settings

Tabs, unchanged: General, Downloads, Connections, Network, Browsers.

Changes from the screenshots:

- General keeps open at login, show in menu bar, show in Dock, watch the clipboard and the notification options. "Show in menu bar" and "Show in Dock" can't both be off. The second switch turns back on with a short note.
- Connections keeps the slider and the queue stepper. "Open extra connections" becomes "After the first connection starts" or "All at once", with the first as the default. Flow's read-only "Retry policy" line becomes a real setting: "Retry a failed connection" with a 0 to 10 stepper, default 5.
- Network shows "Uses your Mac's network and proxy settings" and an optional custom user agent. Manual proxies wait for a later release.
- Browsers changes the most:
  - Each browser gets a row with its icon, name and a verified status: Connected, Not connected, Needs reload or Not installed. A Test button sends a round trip and shows the result.
  - The Catch downloads switch lives here and in the menu bar popover. The app is the source of truth and the extension mirrors it. Flow's "Controlled in the extension" note goes away.
  - Below the switch: "Only catch files larger than [1] MB" and "Never catch on these sites (Edit…)".
  - A Sign-in sharing list shows each site the user allowed, with Remove.
  - The Send page shortcut keeps its recorder. Its help text names the browsers where it works and says macOS will ask for permission once per browser.

## Onboarding

Flow 0.1.2 had three pages: Welcome, "Where should downloads go?" and "Add Flow to your browsers". Dowlio keeps the same sheet, page dots and Back and Continue buttons, and uses four pages.

1. Welcome. Segmented bar animation, then "Dowlio splits each download across several connections, so big files finish sooner. When a connection finishes early, it takes over half of the slowest one's remaining work." Flow's copy claimed 32 connections, but the setting caps at 16, so Dowlio's copy gives no number.
2. Where should downloads go? Download folder, sort into category folders, open at login, show in menu bar, show in Dock. Unchanged from Flow.
3. Add Dowlio to your browsers. One row per installed Chromium browser with Add. Add opens the browser's extensions page and walks through Load unpacked. The row turns to "Connected" only after a real handshake. Browsers that aren't installed don't appear. The menu-bar note stays at the bottom.
4. Your shortcut. A recorder with ⌥⇧D, then Try it now. Pressing it on a browser page triggers the Automation prompt while the explanation is on screen.

Every page has Skip. Settings › General has Show Welcome Again.

## Toasts and notifications

- Catch toast, from PDF page 5. It drops from the menu bar: "Added to Dowlio · file name · size", a segmented bar, and Download in Browser Instead and Show.
- Finished notification, from PDF page 24, with Show in Finder and Open. Several finishing together collapse into "3 downloads finished".
- Disk-full alert, from PDF page 24, with Choose Another Folder…, Manage Storage… and Keep Paused.

## App icon

A blue rounded square with a down arrow over a four-piece segmented bar, as in PDF page 24. Below 64 px, drop the segmented bar.

## Menu bar icon

We want it to be the same down arrow and 3/4 peice segmented bar not in colour, also match the size of most menu bar icon sizes
