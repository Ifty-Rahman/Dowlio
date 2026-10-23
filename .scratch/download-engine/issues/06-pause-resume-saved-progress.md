# 06: Pause, resume and saved progress

**What to build:** The user can pause a download and resume it later without losing bytes. Progress is saved about once a second in a way a crash can't corrupt. A resumed download asks for the original link again, falls back to the last working link, and keeps its segments only if the server still has the same file. A file that changed on the server restarts from zero. Snapshots say whether a download can resume.

**Blocked by:** 02

**Status:** resolved

- [x] Pause stops every connection and saves the manifest. Resume fetches only the missing bytes, and the hash matches.
- [x] The manifest holds format version, identifier, original and final URLs, validator, size, planned name, connection setting, referrer, user agent and each segment's start, end and received. It never holds cookies.
- [x] The data file is flushed before each manifest save, and the manifest is written atomically about once a second and on every state change.
- [x] Resume requests the original URL. If it returns 403, 404 or 410, the saved final URL is tried. If both fail, the download is Failed with link expired.
- [x] A validator mismatch on resume restarts from zero. A 200 to a ranged request restarts from zero once. A second change in a row fails with server changed file.
- [x] Without a strong validator the download still segments, but a resume starts over.
- [x] Snapshots carry "can resume", false for servers without range support or without a known size.

## Comments

Implemented with 11 tests in `PauseResumeTests`, all at the engine interface against the test server.

- `pause(_:)` and `resume(_:)` work within one engine instance. Restoring a partial file at launch is ticket 07, and it can rely on the manifest this ticket writes.
- Referrer and user agent are new request options, sent on every request.
- The manifest is saved after the probe, every fourth progress tick (about once a second), on pause or cancel, and on failure. Counts are read before the data file is flushed, so they never lead it.
- A 200 to a segment request counts as a changed file only when the request carried `If-Range`. Without a validator it still fails as range not supported, which ticket 05 turns into the one-connection fallback.
- The test server now honours `If-Range`, and can change a file after a number of requests or give it a new ETag on every request.
- Tests that hold replies use an idle timeout longer than the hold, so a held reply isn't taken for a stalled connection.
