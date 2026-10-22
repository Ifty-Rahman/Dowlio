# Phase 7: Queue and recovery

## Goal

Dowlio handles many downloads and bad conditions without the user's help. It runs a queue, starts it on a schedule, limits speed, and recovers from expired links, a full disk, sleep and network changes.

## Before you start

Phase 6.

## How it's built

### Queue

- `DownloadQueue` in `DowlioEngine` starts downloads up to "Downloads at once from the queue" (default 3) and keeps the rest queued. Order is stored in the database, so it survives restarts.
- The queue window follows PDF page 22. Rows can be dragged, and ⌘↑ and ⌘↓ move the selection. Columns are drag handle, number, name, size and start time.
- A global connection budget of 32 connections is shared by all running downloads, so several downloads don't open hundreds of connections between them.

### Schedule

- "Start the queue at" and "Pause the queue at", with a time and days of the week.
- Scheduling uses a timer inside the running app. If the Mac sleeps past the start time, the queue starts on wake.
- While the queue runs, `ProcessInfo.beginActivity(options: .idleSystemSleepDisabled)` keeps the Mac awake. The activity ends when the queue empties.
- "When the queue finishes" offers Do nothing, Quit Dowlio or Sleep. Sleep uses an Apple Event to System Events, which triggers its own Automation prompt the first time.

### Speed limit

- `RateLimiter` is a token bucket shared by every connection. When the bucket is empty, the engine suspends that connection's data task until tokens refill, then resumes it.
- It has a global limit (Off or N MB/s), a per-download limit in the detail window, and the "Slow down to 2 MB/s" switch in the menu bar popover.

### Recovery

- Link expired. A `403`, `404` or `410` on a resume of a download that worked before becomes `linkExpired`. The row says "Link expired · Send it again from the browser". When the same file arrives again from the extension, matched by file name, size and validator, Dowlio swaps in the new URL and keeps the downloaded segments. This is NDM's "Renew URL" idea.
- Disk full. Before starting, Dowlio checks free space against the size. During the download, `ENOSPC` pauses the job and shows the disk-full alert from design.md.
- Network changes. `NWPathMonitor` pauses retries while the network is down and resumes them when it returns, without using up retry attempts.
- Sleep and wake. On wake, every downloading job checks its connections and restarts the stalled ones.
- Stall detection. A connection that receives nothing for 60 seconds is dropped and its range goes back to the planner.
- Server changed file. The job restarts from zero and notes "The file changed on the server, so Dowlio started it again."

### Duplicates and naming

- Adding a URL that's already in the list asks "Already in your downloads. Download again?" with Show and Download Again.
- File names come from `Content-Disposition`, then the final URL path, then the page title for media. They're cleaned of `/`, `:` and control characters, and capped at 200 bytes. Conflicts follow the "If a file with the same name exists" setting: Keep both, Replace (after confirmation) or Skip.

## Steps

1. Build `DownloadQueue`, its persistence and the connection budget.
2. Build the queue window.
3. Build the schedule, keep-awake and "When the queue finishes".
4. Build `RateLimiter` and its three controls.
5. Build each recovery case, with a test server scenario for each.
6. Build duplicate prompts and the naming rules.
7. Run a 24-hour soak test: 200 queued files of mixed sizes from the test server with random faults. Record the result in `docs/benchmarks.md`.
8. Release `v0.5.0`.

## Done when

- The soak test finishes every file with matching hashes and no leftover `.dowlio` packages.
- Pulling the network for 2 minutes mid-download and restoring it resumes every download with no failures.
- Closing the lid and opening it later resumes downloads.
- A full test disk image pauses the download with the alert. Freeing space and resuming finishes it.
- A speed limit of 1 MB/s holds within 10 percent over a minute.

## Out of scope

Auto-update and release hardening (phase 8).
