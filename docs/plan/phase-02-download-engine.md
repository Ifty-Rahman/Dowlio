# Phase 2: Download engine

## Goal

A segmented, resumable HTTP download engine in `DowlioEngine`, tested against a local fault-injecting server and usable from a command-line tool. No interface yet.

## Before you start

Phase 1.

## How it's built

Follow "The download engine" and "Files on disk" in architecture.md. In short:

- `DownloadEngine` is an actor that owns every `TransferJob`. Each job has a state machine with these states: `probing`, `downloading`, `paused`, `retrying(attempt, nextTry)`, `finalizing`, `completed`, `failed(DownloadError)` and `cancelled`.
- `Prober` sends the `bytes=0-0` probe and returns a `RemoteFile`: final URL, size, validator, ranges supported, MIME type and suggested name.
- `SegmentPlanner` is pure logic. It splits a size into ranges, picks the next range to steal, and lowers the count after refusals. It does no I/O, so it's easy to test thoroughly.
- `SegmentConnection` wraps one `URLSession` and one data task. It reports bytes as they arrive.
- `PartFile` owns the `.dowlio` package: a preallocated `data` file written with `pwrite` from one serial queue, and the atomic `manifest.json`.
- `Finalizer` checks coverage, moves the file into place, resolves name conflicts and sets the quarantine attribute.
- `DownloadError` is a closed enum, and every case maps to one sentence of user copy later. Cases: `notFound`, `forbidden`, `needsSignIn`, `linkExpired`, `serverChangedFile`, `rangeNotSupported`, `diskFull`, `destinationNotWritable`, `network(underlying)`, `tooManyRetries`, `cancelled`.
- Progress goes out as an `AsyncStream<JobSnapshot>` at most 4 times a second. A snapshot holds bytes done, speed, time left and each segment's range and progress. The segmented bar in phase 3 draws from it.

## Steps

1. Write the `Tests/Support/TestServer`. It uses `NWListener` on a random loopback port. Per file it can switch on or off: range support, a strong ETag, throttling to N bytes per second per connection, dropping a connection after N bytes, changing the file mid-download, wrong `Content-Range`, `429` with `Retry-After`, and a limit on parallel connections.
2. Write `SegmentPlanner` and its tests: splitting, the 1 MiB minimum, stealing at the midpoint, never splitting below the minimum, and lowering the count.
3. Write `Prober` and its tests against the server: range support, no range support, redirects, missing length, `Content-Disposition` names.
4. Write `PartFile`: preallocation, writes at offsets, manifest save and load, coverage check. Test reopening after a simulated crash.
5. Write `SegmentConnection` with one `URLSession` per connection. Check `Content-Range` on every reply.
6. Write `TransferJob`, combining the pieces: ramp-up after the first bytes, work stealing, retry with backoff and jitter, `If-Range`, and fallback to one connection.
7. Write `Finalizer`: the coverage check, atomic move, "Keep both" naming, the quarantine attribute and cleanup on cancel.
8. Write `DownloadEngine`: add, pause, resume, cancel, and restore every job from its manifest at launch.
9. Write `dowlio-cli`. `dowlio-cli get <url> [-c 8] [-o dir]` prints live progress. `dowlio-cli resume <package>` continues a paused download.
10. Benchmark. Download a large public file, such as an OS image from a major CDN, with 1, 4, 8 and 16 connections. Record the results in `docs/benchmarks.md`. Run it once with one shared `URLSession` and once with one session per connection, to confirm the session choice.

## Done when

- Every scenario the test server supports has a passing test. That includes a file that changes mid-download, which must restart cleanly and never mix old and new bytes.
- Killing `dowlio-cli` mid-download and running `resume` finishes with a file whose SHA-256 matches the original.
- A server without range support downloads correctly over one connection.
- The benchmark shows segmented downloads beating one connection on a throttled test file, and the numbers are in `docs/benchmarks.md`.

## Out of scope

Speed limits and the queue (phase 7), HLS (phase 6), the interface (phase 3).
