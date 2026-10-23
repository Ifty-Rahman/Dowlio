# 01: One-connection download, URL to finished file

**What to build:** A developer runs `dowlio-cli get <url>` and the file downloads over one connection into a partial file next to the destination, then appears in the destination folder as the finished file. Progress prints while it runs. This is the tracer bullet through every layer: the shared models, the engine's "add" operation and snapshot stream, the probe, one connection, the partial file, the finishing step and the command-line tool. The test server exists and serves files with and without range support.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Adding a download for a file on the test server ends in Completed, and the finished file's SHA-256 matches the served file.
- [x] The probe uses `GET` with `Range: bytes=0-0`. A server without range support still completes, using the probe's own response.
- [x] While downloading, the bytes go into a `.dowlio` partial file in the destination folder. After completion, no partial file remains.
- [x] The finished file appears with an atomic rename, and only after a check that every byte is present.
- [x] If a file with the same name exists, the download fails instead of overwriting it. Ticket 09 adds naming.
- [x] Snapshots report state, bytes received, total size and file name, and the stream ends after Completed.
- [x] `dowlio-cli get` prints progress and exits with 0 on Completed and non-zero on Failed. A smoke test runs it against the test server.
- [x] No test touches the internet.

## Comments

Implemented with 15 engine and command-line tests. Review fixes, beyond the criteria above:

- the probe runs before the partial file exists, so a failed probe leaves nothing behind;
- a second download of the same file gets a numbered partial file;
- the file is named from the final URL after redirects;
- both range replies must match the requested range exactly;
- `dowlio-cli get` prints a progress line every second, also while stalled.

Temporary errors that later tickets remove: file exists (09), unexpected status (04), range not supported as a failure (05).
