# Download engine

Status: ready-for-agent

Phase 2 of the build plan (`docs/plan/phase-02-download-engine.md`). Words follow `GLOSSARY.md`. Decisions follow `docs/plan/architecture.md` and ADRs 0001 to 0003.

## Problem statement

Browsers download a large file over one connection. When the connection is slow, throttled per connection, or drops, the user waits longer than their line allows, and an interruption often means starting over. Dowlio exists to fix that. It has an app shell and a release pipeline, but no way to download anything yet. Every later phase (the app, Catch downloads, Send to Dowlio, media) needs a download engine that is fast, survives interruptions, never corrupts a file and never loses progress it could keep.

## Solution

A download engine that splits a file into segments and fetches them over several connections at once, when the server allows it. It keeps each download's progress in a partial file next to the destination, so pausing, quitting, crashing or losing the network never loses downloaded bytes the server lets it keep. It checks every reply from the server, restarts cleanly when the file changes on the server, and only puts a file in its folder after checking that every byte is present. It reports progress several times a second, including each segment's progress, for the segmented bar the app will draw.

In this phase, a developer drives the engine from a command-line tool. Phase 3 puts the interface on top of the same engine interface.

## User stories

### Starting a download

1. As a Mac user, I want a large file to download over several connections at once, so that it finishes as fast as my line allows.
2. As a Mac user, I want Dowlio to check whether the server supports segmented downloads before splitting the file, so that downloads from simple servers still work.
3. As a Mac user, I want a download from a server that doesn't support ranges to work over one connection, so that I can download from any server.
4. As a Mac user, I want a file whose size the server doesn't report to download over one connection, so that streamed or generated files still download.
5. As a Mac user, I want Dowlio to use 8 connections by default, so that I get a fast download without tuning anything.
6. As a Mac user, I want to choose up to 16 connections per download, so that I can go faster on servers that allow it.
7. As a Mac user, I want Dowlio never to use more than 16 connections per download, so that servers don't block me for opening too many.
8. As a Mac user, I want small files split into fewer segments than my connection setting, so that tiny segments don't waste time.
9. As a Mac user, I want a file under 2 MiB to download over one connection, so that small files start and finish without overhead.
10. As a Mac user, I want Dowlio to open the extra connections only after the first one starts receiving data, so that a broken link or a server that refuses ranges is found with one request instead of eight.
11. As a Mac user, I want the option to open all connections at once, so that I can save a fraction of a second on servers I trust.
12. As a Mac user, I want redirects followed to the real file, so that download links behind redirects work.
13. As a Mac user, I want the file named from the server's suggested name when it gives one, so that the file has its proper name.
14. As a Mac user, I want the file named from the link when the server suggests no name, so that I never get an unnamed file.
15. As a Mac user, I want unsafe characters removed from file names, so that a strange name from a server can't break the save.
16. As a Mac user, I want a plain `http://` link to download as given and be marked "Not secure", so that old mirrors work and I know the connection wasn't encrypted.
17. As a Mac user, I want Dowlio to reserve the full file size on disk before downloading, so that a file that can't fit fails in the first second instead of near the end.
18. As a Mac user, I want a clear "Not enough space" error when the file can't fit, so that I know to free space or pick another folder.
19. As a Mac user, I want a clear error when the destination folder can't be written to, so that I know to pick another folder.

### While downloading

20. As a Mac user, I want a connection that finishes early to take over half of the largest remaining segment, so that no single slow segment holds up the end of the download.
21. As a Mac user, I want segments never split below 1 MiB, so that the end of a download doesn't fill up with tiny requests.
22. As a Mac user, I want to see bytes downloaded, total size, speed and time left, so that I know how long to wait.
23. As a Mac user, I want to see each segment's range and progress, so that the segmented bar shows what's happening.
24. As a Mac user, I want to see how many connections are active, so that I know whether the server allows segmenting.
25. As a Mac user, I want to know whether a download can resume, so that I know whether pausing loses progress.
26. As a Mac user, I want progress updates smooth but not more than about 4 times a second, so that the display stays readable and cheap.

### Interruptions and retries

27. As a Mac user, I want a dropped connection retried automatically, so that a brief network problem doesn't stop my download.
28. As a Mac user, I want retries to wait a little longer each time, so that Dowlio doesn't hammer a struggling server.
29. As a Mac user, I want Dowlio to respect a server's request to wait before retrying, so that it behaves well with busy servers.
30. As a Mac user, I want to see that a download is Retrying while it waits, so that I know it hasn't frozen.
31. As a Mac user, I want a download to become Failed after a segment fails 5 times, so that a broken download doesn't retry forever without me knowing.
32. As a Mac user, I want a Failed download to keep its partial file, so that Retry continues from where it stopped.
33. As a Mac user, I want Dowlio to use fewer connections when a server refuses or resets them, so that the download continues instead of failing.
34. As a Mac user, I want Dowlio to remember a host's lower connection limit, so that later downloads from that host don't trigger the same refusals.
35. As a Mac user, I want Dowlio to switch to one connection when a server gives bad range replies, so that the download still finishes.
36. As a Mac user, I want a connection that receives nothing for 60 seconds treated as failed and retried, so that a silent stall doesn't freeze the download.

### Correctness

37. As a Mac user, I want every reply from the server checked against what was asked for, so that a wrong reply never writes bytes into the wrong place.
38. As a Mac user, I want Dowlio to notice when the file changes on the server mid-download, so that my file never mixes bytes from two versions.
39. As a Mac user, I want a changed file to restart from the beginning automatically, so that I still end up with a correct file.
40. As a Mac user, I want the finished file put in place only after every byte is confirmed present, so that I never open a half-written file.
41. As a Mac user, I want the finished file to appear in one step, so that no other app sees it half-moved.

### Pause, resume, cancel

42. As a Mac user, I want to pause a download and resume it later, so that I can free my connection for something else.
43. As a Mac user, I want a resumed download to fetch only the bytes it doesn't have yet, so that pausing costs nothing.
44. As a Mac user, I want a resumed download to request the original link again, so that an expired signed link is renewed.
45. As a Mac user, I want Dowlio to try the last working link when the original link no longer works, so that downloads from one-time links can still resume.
46. As a Mac user, I want downloaded segments kept on resume only if the server still has the same file, so that a resumed download is never corrupt.
47. As a Mac user, I want a clear "Link expired" error when neither link works any more, so that I know to get a fresh link.
48. As a Mac user, I want pausing a download from a server that can't resume to discard its progress only after I confirm it, so that I don't lose progress by accident. (The engine reports that it can't resume. The interface asks.)
49. As a Mac user, I want Cancel to delete the partial file and remove the download, so that cancelled downloads leave nothing behind. (The interface asks first.)
50. As a Mac user, I want a download whose partial file I deleted in Finder to start over from the beginning the next time it runs, so that it keeps working without fuss.

### Surviving quits and crashes

51. As a Mac user, I want every download's progress saved about once a second, so that a crash loses at most a second of progress.
52. As a Mac user, I want saved progress never to claim more bytes than are safely on disk, so that a crash can never leave a hole in the file.
53. As a Mac user, I want paused and unfinished downloads restored after quitting or a crash, so that I can continue them.
54. As a Mac user, I want a partial file to hold everything needed to resume it, so that it works even if Dowlio forgets about it.
55. As a Mac user, I want the referrer and user agent a download needs kept in its partial file, so that it can resume after a restart.
56. As a Mac user, I want cookies never written to disk, so that my sign-in sessions don't leak into files.

### Finished files

57. As a Mac user, I want an existing file with the same name kept, with the new file saved as "name 2", so that nothing I have is overwritten.
58. As a Mac user, I want the option to replace or skip instead of keeping both, so that I can choose how name conflicts work.
59. As a Mac user, I want finished files marked as downloaded from the internet, with Dowlio named as the downloader, so that macOS checks downloaded apps and disk images the same way it does for browser downloads.

### Developer

60. As a developer, I want a command-line tool that downloads a URL with live progress, so that I can test the engine without an interface.
61. As a developer, I want the command-line tool to resume a partial file, so that I can test crash recovery by killing the process.
62. As a developer, I want a local test server that injects faults on demand, so that every failure case has a repeatable test.
63. As a developer, I want tests that never touch the internet, so that CI is fast and gives the same result every run.
64. As a developer, I want the segment planner testable as pure logic, so that its edge cases are cheap to cover exactly.
65. As a developer, I want a benchmark that compares 1, 4, 8 and 16 connections on a real CDN, so that the speed claim and the one-session-per-connection choice are proven.
66. As a developer working on phase 3, I want one engine interface for adding, pausing, resuming, retrying, cancelling and restoring downloads, plus a snapshot stream, so that the app needs nothing else from the engine.

## Implementation decisions

### Modules

- **DowlioCore** gains the shared models: download identifier, download state, download error, request options, download snapshot and segment progress. These types are what the app sees. They must be `Sendable` and free of engine internals.
- **DowlioEngine** is a new module. It holds the engine actor and its parts: prober, segment planner, connection, partial file, finalizer, retry policy and host limit store.
- **dowlio-cli** is a new executable product in the package. CI builds and tests it, but it never ships in the app or in a release.
- **DowlioTestSupport** is a new test-only target with the fault-injecting test server, shared by engine tests and later phases.

### Engine interface (seam 1)

The engine is an actor and the only entry point. Its operations:

- Add a download from a URL, a destination folder and request options. Returns the download's identifier. The download starts at once in this phase. Phase 7 adds the queue.
- Pause, resume, retry and cancel by identifier. Resume applies to Paused downloads, Retry to Failed ones. Cancel deletes the partial file and removes the download.
- Restore a download from a partial file. Restoring an unknown partial file adds it as Paused. This is the same path the app uses at launch and when the user double-clicks a partial file (phase 3).
- A snapshot stream per download, plus a stream of all downloads' snapshots. Each stream emits on every state change and at most 4 times a second while bytes arrive.

Request options: connection count (1 to 16, default 8), "open extra connections" mode (after the first connection starts receiving data, which is the default, or all at once), name conflict policy (keep both, which is the default, replace or skip), referrer, user agent, and cookies. Cookies are held in memory only.

The engine doesn't ask the user anything. Confirmations for Cancel and for pausing a download that can't resume belong to the interface, which reads the snapshot's "can resume" flag.

### Download states

Engine states and what the interface shows:

| Engine state | Shown as | Notes |
|---|---|---|
| probing | Downloading | Probe request in flight |
| downloading | Downloading | |
| retrying(attempt, next try time) | Retrying | Waiting to retry at least one connection |
| paused | Paused | |
| finalizing | Downloading | Coverage check and move |
| completed | Completed | |
| failed(error) | Failed | Partial file kept |
| cancelled | (removed) | Last event before the download disappears |

Queued doesn't exist in the engine yet. Phase 7 adds it.

### Snapshot shape

A snapshot holds: identifier, state, file name, destination folder, display host, total size (when known), bytes received, speed in bytes per second smoothed over the last 5 seconds, time remaining (when computable), active connection count, "can resume", "not secure" (plain HTTP), the error when Failed, and one entry per segment with its start, end, bytes received and whether a connection is working on it.

### Errors

`DownloadError` is a closed set. Each case maps to one sentence of user copy in phase 3: not found, forbidden, needs sign-in, link expired, server changed file (only when restarting fails), range not supported (only used internally to trigger the fallback), not enough space, destination not writable, incomplete file (the bytes received don't cover the file, so the finishing check refuses it), network (with the underlying error), too many retries, cancelled. Ticket 01 added two temporary cases, both gone now: file exists, replaced by the name conflict policy in ticket 09, and unexpected status, replaced by the status mapping and retries in ticket 04.

Status mapping on the first request: 401 is needs sign-in, 403 is forbidden, 404 and 410 are not found. On resume, a 403, 404 or 410 from the original URL leads to the saved final URL. If that fails too, the download fails as link expired.

### Probe and plan

- Probe with `GET` and `Range: bytes=0-0` with identity encoding. A 206 with a full `Content-Range` means ranges work and gives the size. A 200 means one connection, and the probe's own response becomes the download.
- Record the original URL, final URL, strong ETag or Last-Modified, content type and suggested name. A weak ETag counts as no validator. Without a validator, the download can still segment, but a resume after restart starts over, because a changed file can't be detected.
- Segment count is the smallest of: the connection setting, the host's learned limit, and the size divided by 1 MiB, never below 1.
- Unknown size: one connection, no disk reservation, can't resume.

### Segment planner (seam 2)

Pure logic with no I/O and no clock:

- Plan: given size, connection count, host limit and the 1 MiB minimum, return contiguous segments covering the file exactly.
- Steal: given the remaining ranges, return which range a free connection takes. It takes the second half of the largest remaining range, and only if both halves stay at 1 MiB or more. Otherwise it returns nothing and the connection closes.
- Lower: given refusal events, return the new connection limit for the host. Each refusal or reset lowers it by one, never below 1.

### Connections

- One `URLSession` per connection, so each segment gets its own TCP connection rather than being multiplexed onto one. The benchmark must confirm this beats one shared session. If it doesn't, record the finding in an ADR and switch.
- Every ranged request sends `Range` and `If-Range` with the validator.
- Every 206 must carry a `Content-Range` whose start, end and total match the request. A mismatch, a `Content-Encoding` on a ranged reply, or `multipart/byteranges` drops the plan to one connection.
- A 200 to a ranged request means the file changed. The download discards its segments and restarts from zero once. A second change in a row fails with server changed file.
- Per-connection idle timeout of 60 seconds. It counts as a retryable failure.

### Retry policy

- Retryable: network errors, timeouts, 408, 429 and 5xx. Not retryable: other 4xx.
- Up to 5 attempts per segment. The delay starts at 1 second, doubles each attempt, carries plus or minus 20 percent jitter, and is capped at 30 seconds. `Retry-After` replaces the delay, up to 5 minutes.
- When any segment exhausts its attempts, the whole download becomes Failed with too many retries, and every connection stops.
- 429, 503 and connection resets also lower the host limit.
- Tests inject a fast policy.

### Host limit store

A small store keyed by host. It starts in memory. Phase 3 persists it in the database behind the same interface.

### Partial file

- A package named after the planned file name with a `.dowlio` suffix, created in the destination folder. If that package name exists, a number is added.
- It contains a data file and a manifest. The data file is reserved at full size when the size is known. Not enough space fails the download at once.
- Segments write at their own offsets from one serial writer.
- The manifest holds: format version, download identifier, original URL, final URL, validator, total size, planned file name, connection setting, referrer, user agent, and each segment's start, end and received count. It never holds cookies.
- Durability rule: before each manifest save, the data file is flushed to disk. The manifest's received counts may lag the data file, never lead it. A crash can only cause re-downloading, never a hole.
- The manifest is saved atomically about once a second, and on every state change.
- If the package is missing when a download runs, the download starts over in a new package.

### Finalizer

- Checks that the segments cover byte 0 to the total size exactly. When the size is unknown, it checks that the stream ended cleanly.
- Flushes, then moves the data file to its final name with an atomic rename in the same folder, then deletes the package.
- Name conflicts: keep both adds " 2", " 3" and so on before the extension. Replace overwrites only when the policy says so. Skip keeps the existing file. The download completes without moving the new file, and the package is deleted.
- Sets the quarantine attribute with Dowlio as the agent and the source URL as the origin, through Foundation's quarantine resource values.

### File names

The suggested name comes from `Content-Disposition` (`filename*` first, then `filename`). Otherwise it's the last path component of the final URL, percent-decoded. Otherwise it's "download". When the name has no extension and the content type maps to one, the extension is added. `/`, `:` and control characters are removed. Leading dots are removed, so the file isn't hidden. Names are capped at 200 bytes.

### Plain HTTP

Per ADR 0003, the app's Info.plist turns App Transport Security off. The snapshot's "not secure" flag is set for every `http://` download. The engine never upgrades the URL.

### Command-line tool

- `get` takes a URL, with an optional connection count and output folder, and prints one progress line per second: percentage, bytes, speed, time left, connections, state. Ctrl-C pauses and prints the partial file path.
- `resume` takes a partial file path and continues it.
- The exit code is zero on Completed and non-zero on Failed, with the error printed.

## Testing decisions

- A good test drives the engine only through its public interface and checks only what a user could observe: the finished file's SHA-256, the order of states, what's left on disk, the error, and the snapshots' segment ranges. Tests never reach into the engine's internals or check private method calls. If an internal piece is rewritten and behaviour stays the same, no test changes.
- **Seam 1, the engine interface.** Real loopback HTTP against the test server, and a fresh temporary folder per test. The test server serves generated files with known hashes. Per file, it can switch range support and strong ETags on or off, throttle per connection, drop a connection after N bytes, change the file after N bytes served, send a wrong `Content-Range`, answer 429 with `Retry-After`, answer a status for the first N requests, cap parallel connections, redirect (including one-time redirects that work once), omit the length, and suggest a name with `Content-Disposition`. Faults trigger on byte and request counts, not on timing, so results are the same every run. Each user story above about downloading, interruptions, correctness, pause and resume, survival and finished files gets at least one test here.
- Crash recovery has two tests. In process: drop the engine without finalizing, create a new engine and restore from the partial file. Out of process: start `dowlio-cli get`, kill it with SIGKILL mid-download, run `dowlio-cli resume`, and compare hashes.
- **Seam 2, the segment planner.** Pure unit tests with table-driven cases: plan coverage and contiguity for many sizes and counts, the 1 MiB floor, stealing from the largest range, refusing to steal below the floor, several connections finishing at once, and lowering the limit to a floor of 1.
- The command-line tool gets a smoke test: one full download from the test server, checking the exit code and the hash.
- Prior art: the package uses Swift Testing (`@Test`, `#expect`) in the existing core tests. There's no network test prior art yet. The test server here becomes the prior art for later phases.
- Tests run in CI through the existing test script. No test touches the internet.
- The benchmark is manual and its results go into a benchmarks document: 1, 4, 8 and 16 connections, and one shared session against one session per connection, on a large public file from a major CDN.

## Out of scope

- The interface, history database, settings and notifications (phase 3).
- Registering `.dowlio` as a file type, its Finder icon, and opening it by double-click (phase 3). The format itself is in scope.
- The queue, Queued state, schedule, speed limits, the global connection budget, network-change and sleep handling, duplicate detection, expired-link renewal from the browser, and disk-full during a download (phase 7).
- Catch downloads, Send to Dowlio, cookies from the browser (phases 4 and 5). The engine accepts cookies in memory, but nothing supplies them yet.
- HLS, yt-dlp and merging (phase 6).
- Persisting the host limit store (phase 3).

## Further notes

- The welcome copy in Flow says a finished connection takes over the slowest segment. The engine takes over the largest remaining one, which is the measurable proxy. Phase 3 copy should say "the largest remaining part" or stay vague.
- The quarantine attribute means a downloaded `.app` or `.dmg` from Dowlio shows Gatekeeper's prompt on first open, exactly like a browser download. That's intended.
- `httpMaximumConnectionsPerHost` must be raised above its default of 6 for any shared session, or connections beyond six queue silently.
