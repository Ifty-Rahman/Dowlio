# Phase 3: App and interface

## Goal

A usable Mac download manager. The user pastes or drops a link, watches it download in the library window or from the menu bar, and finds it again in history. It's the first build worth sharing on GitHub.

## Before you start

Phases 1 and 2. Read design.md.

## How it's built

- SwiftUI with the Observation framework (`@Observable`). One `AppModel` on the main actor subscribes to the engine's snapshot streams and publishes rows to the views.
- The design tokens live in `App/Design/DowlioDesign.swift`: accent colour asset, text styles, spacing and radii from design.md. `docs/flow-ui-reference/swift/FlowDesign.swift` is the reference.
- `SegmentedBar` is one view used everywhere. It draws each segment's progress from a `JobSnapshot`.
- The menu bar uses AppKit: an `NSStatusItem` with an `NSPopover` hosting SwiftUI. SwiftUI's `MenuBarExtra` can't open its window from code, and phases 4 and 5 need to open the catch toast and the Send panel from code.
- Dock and menu bar presence use `NSApp.setActivationPolicy`. With Dock off, the policy is `.accessory`. Closing the last window keeps the app running.
- History goes into `DowlioStore` with GRDB. The library reads it through a GRDB `ValueObservation`, so the list updates live.
- Launch at login uses `SMAppService.mainApp`.
- Notifications use `UserNotifications`.
- The app icon follows design.md.

## Steps

1. Add `DowlioStore`: the downloads table, migrations, queries per sidebar filter and category, search by file name and host.
2. Add `AppModel`, joining the engine and the store. Write engine state changes to the store.
3. Build the main window: sidebar, toolbar, row view with `SegmentedBar`, empty state, search and the free-space footer. Use the screenshots as reference.
4. Add actions: pause, resume, cancel with confirmation, Show in Finder, Copy Link, Remove from List and Delete File. Delete File asks first.
5. Build the inspector and the detail window from design.md.
6. Build the New Download sheet with the live file card. It probes as the user types or pastes. Add ⌘N, paste anywhere with ⌘V, and dropping links on the window and the Dock icon.
7. Build the menu bar item and popover, and the ⋯ menu with Settings, Report a Problem and Quit.
8. Build Settings with the General, Downloads and Connections tabs from design.md. Network and Browsers show placeholders until phase 4.
9. Build onboarding pages 1 and 2. Pages 3 and 4 come in phases 4 and 5. Add Show Welcome Again in Settings.
10. Add the quit guard. Quitting with active downloads asks "Stop 2 downloads and quit? They can resume next time." with Quit and Cancel.
11. Add the categories rule. The file extension and MIME type map to Video, Audio, Documents, Archives or Apps & Disk Images. When "Sort into category folders" is on, the file goes to `Downloads/<Category>`.
12. Add the finished notification and the clipboard watcher. The watcher is off by default and suggests a link copied from outside the app.
13. Release `v0.1.0` through the phase 1 pipeline.

## Done when

- A fresh install shows onboarding, then the empty state.
- Pasting a link downloads it with a live segmented bar. Pause and resume work from the row, the toolbar and the popover.
- Quitting mid-download and reopening restores the download as paused, and resuming finishes it.
- With Dock off and the window closed, downloads continue and the popover shows them.
- Every screen works in light and dark mode and with Increase Contrast.
- VoiceOver reads each row as name, state, progress and speed.

## Out of scope

The Browsers and Network tabs (phase 4), the queue window and schedule (phase 7), Sparkle (phase 8).
