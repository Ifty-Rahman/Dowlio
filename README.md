# <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Dowlio" width="60" height="60" align="absmiddle">&nbsp;&nbsp;Dowlio

*A fast, private, native download manager for Mac*

![Platform](https://img.shields.io/badge/Platform-macOS_14+-black) ![Architecture](https://img.shields.io/badge/Architecture-Apple_Silicon/Intel-black) ![Privacy](https://img.shields.io/badge/Privacy-No_accounts,_no_tracking-success)

**Dowlio** splits each download across several connections, so large files arrive faster. It lives in your menu bar, keeps going when you close the window, and picks up where it left off after a quit. With Dowlio Connect, downloads you start in Chrome, Arc, Brave or Edge finish in Dowlio.

---

## 📥 How to Download Dowlio

Get `Dowlio-<version>.dmg` from the [latest release](../../releases/latest). Dowlio needs macOS 14 or later and runs on Apple silicon and Intel Macs.

Dowlio isn't notarized yet, because notarization needs a paid Apple Developer account. macOS blocks the first launch. You approve it once:

1. Open the DMG and drag Dowlio to Applications.
2. Open Dowlio. macOS says it can't verify the app. Click Done.
3. Open System Settings, then Privacy & Security.
4. Scroll to the message about Dowlio and click Open Anyway. Confirm with your password.

Dowlio opens normally after that, and updates won't ask again.

From Terminal, this does the same as steps 2 to 4:

```
xattr -dr com.apple.quarantine /Applications/Dowlio.app
```

---

## ✅ Key Features

- **Catch downloads:** with Dowlio Connect added, a download you start in a Chromium browser moves to Dowlio and starts at once. If Dowlio is quit or can't take it, the browser keeps it.
- **Send to Dowlio:** hand Dowlio a link from the browser's right-click menu. Nothing downloads until you choose Download.
- **Faster downloads:** each file is split into segments fetched over several connections at once, from 1 to 16 per download (8 by default). You see every segment fill on a segmented progress bar.
- **Take over slow segments:** when a connection finishes early, it can split the slowest remaining segment and help with it. This is off by default, and a download never has more than 32 segments.
- **Pause and resume:** pause from a row, the toolbar or the menu bar. If a server can't resume, Dowlio tells you before a pause would start the file over.
- **Survives a quit:** quit mid-download and reopen, and each unfinished download comes back paused, ready to continue. If you deleted the partial file, it starts over from its link.
- **Menu bar first:** the icon shows progress while anything downloads. Open it for a summary, pause and resume rows, or add a link without opening the window.
- **Quick add:** paste or type a link in the menu bar panel and start the download right there.
- **Your choice of Dock or menu bar:** keep Dowlio in either, or both. It can start quietly at login, or open only its menu bar icon at every launch.
- **Automatic sorting:** files are grouped into Video, Audio, Documents, Archives, and Apps & Disk Images, and can be saved into matching folders.
- **Queue:** choose how many downloads run at once. The rest wait their turn.
- **A history you can search:** find a download by file name or host, filter by state or category, and see how long a finished one took.
- **Notifications:** get a notice when a download finishes, with Show in Finder and Open. Downloads that finish together collapse into one notice.
- **Plain failure messages:** a failed download says why and what to do next.
- **Marked when not secure:** plain-HTTP links carry a "Not secure" label everywhere they appear.

---

## ⚡ Quick Start

1. Install Dowlio using the steps above.
2. Open Dowlio and follow the short welcome. It asks where downloads should go and how Dowlio should live on your Mac.
3. To catch browser downloads, choose Add next to your browser in the welcome or in Settings › Browsers. See [Dowlio Connect](#-dowlio-connect) below.
4. Paste a link with ⌘V, drop one on the window, or press ⌘N.
5. Check the file name and folder in the New Download sheet, then choose Download.
6. Watch the bar fill. Pause, resume or cancel from the row.

---

## 🌐 Dowlio Connect

Dowlio Connect is Dowlio's extension for Chromium browsers: Chrome, Arc, Brave, Edge and others. Dowlio finds the ones on your Mac and lists each by name in Settings › Browsers.

### Adding it to a browser

Dowlio Connect isn't in the Chrome Web Store yet, so you load it yourself. It takes about a minute:

1. In Settings › Browsers, or in the welcome, choose Add next to your browser. Dowlio copies Dowlio Connect to a folder that doesn't change when Dowlio moves or updates, opens the browser's extensions page, and shows the folder's path with Copy path.
2. In the browser, turn on Developer mode.
3. Click Load unpacked, press ⌘⇧G, paste the path, and choose Select.
4. Dowlio Connect shows a four-digit code, and Dowlio asks whether that browser may connect. Check the code matches and choose Allow.

The browser's row then says Connected. You pair once per browser. When Dowlio updates, it updates Dowlio Connect in every browser for you.

### Catching downloads

Start a download in a connected browser and it moves to Dowlio before the browser shows it. It starts at once and goes to your download folder, sorted like any other. A toast under the menu bar icon says "Added to Dowlio", with Show and Download in Browser Instead. Downloads that arrive within a couple of seconds of each other share one toast, such as "3 downloads caught", which offers Show in Dowlio. With the menu bar icon off, a notification does the same job.

Some downloads always stay in the browser:

- Every download while Dowlio is quit.
- Downloads in incognito windows.
- Files a page builds itself (`blob:` and `data:` links) and `file:` links.
- Anything Dowlio can't take or doesn't answer for within 15 seconds. The browser gets it back, so a download is never lost.

To stop catching, turn off Catch downloads in the Dowlio Connect popup or in Settings › Browsers, or Catch browser downloads in the menu bar. To keep one site's downloads in the browser, choose Never catch on that site in the popup. Settings › Browsers lists those sites, each with Remove.

### Send to Dowlio

Right-click a link and choose Send to Dowlio. The link opens in Quick add from the menu bar, or in the New Download sheet when the menu bar icon is off. Dowlio checks it first and says so when the link is a web page rather than a file. Nothing downloads until you choose Download, and Cancel drops it.

### Cookies

Dowlio Connect passes along a site's cookies with each download it hands over, so files from sites you're logged in to work in Dowlio too. Dowlio keeps them in memory for that download only and never writes them to disk.

---

## 🗂️ Working With Many Downloads

Select downloads the way you do in Finder:

- Click, ⌘-click to add or remove one, and ⇧-click for a range.
- ⌘A selects everything in the current view, and Esc clears the selection.
- ↑ and ↓ move the selection, and ⇧↑ and ⇧↓ extend it.
- Drag a box across rows to select them. Hold ⌘ to add to what is already selected.

Then act on the whole selection from the toolbar, the Download menu or a right-click. Menu items say how many downloads they cover, such as "Pause 3 Downloads". Cancel, Remove from List and Move to Trash ask once for the whole group. The inspector shows the combined size and speed.

Other tools in the library:

- **Inspector:** the percentage, each segment, speed, time left, whether the server can resume, and where the file comes from.
- **Detail window:** double-click a row to see every segment's range and bytes, and a 60-second speed graph.
- **Quick Look:** press Space to preview finished files without opening them.
- **Clear Completed:** tidy the list without touching the files.

---

## ⚙️ Settings

- **General:** open at login, start in the menu bar, show in the menu bar, show in the Dock, notifications, and what happens when a download finishes: nothing, Show in Finder or Open the file.
- **Downloads:** the download folder, sorting into category folders, and what to do when a file with the same name exists: keep both, replace or skip.
- **Connections:** connections per download, downloads at once, how extra connections open, how many times to retry a failed connection, and Take over slow segments.
- **Browsers:** each Chromium browser on your Mac and whether it's connected, with Add, Test and Reload. Also the Catch downloads switch and the sites that are never caught.

---

## 🔒 Privacy

Dowlio has no account and no tracking. It stores what it needs to resume a download and show your history, and the sites you never catch on. It stores no page titles, no cookies and no request bodies. It does keep the page a download came from, because some servers only resume a download for the page that linked to it. Cookies from Dowlio Connect stay in memory for the one download that needs them.

Dowlio Connect talks to Dowlio only on your Mac, at `127.0.0.1`. Dowlio refuses web pages that try to connect, and a browser can do nothing until you allow it with its code. Report a Problem opens a prefilled GitHub issue with only the app and macOS versions. It never includes your links, file names or hosts.

---

## ♿ Accessibility

Dowlio works in light and dark mode and with Increase Contrast. It calms its animations when Reduce Motion is on. With VoiceOver, each download is read as its name, state, progress and speed, in the library and in the menu bar. State is always shown with a word and an icon as well as a colour.

---

## 🔭 Coming Next

- Send to Dowlio for a whole page: choose from the files and media Dowlio finds on it.
- Media downloads from streams and video sites, with audio and video merged.
- A scheduled queue with a speed limit, duplicate checks and recovery for expired links.
- Automatic updates.

---

## 🛠️ Troubleshooting

If you hit a problem or have a question, [open an issue](../../issues). Report a Problem in the menu bar's ⋯ menu starts one with the right details filled in.

---

## ⚖️ License

Copyright © 2026 Ifty Rahman. All rights reserved. The source is public to read, but no license to reuse it is granted yet.
