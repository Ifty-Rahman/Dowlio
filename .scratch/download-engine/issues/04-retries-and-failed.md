# 04: Retries and Failed

**What to build:** A dropped or erroring connection is retried automatically with growing waits, and the download shows as Retrying meanwhile. A segment that fails 5 times makes the download Failed, with its partial file kept, and Retry continues it from where it stopped. Clear errors come back for links that are forbidden, missing or need sign-in.

**Blocked by:** 01

**Status:** resolved

- [x] Network errors, timeouts, 408, 429 and 5xx are retried. Other 4xx aren't.
- [x] Delays start at 1 second, double, carry plus or minus 20 percent jitter and are capped at 30 seconds. `Retry-After` replaces the delay, up to 5 minutes. Tests inject a fast policy.
- [x] A connection dropped after N bytes resumes its segment from the bytes it has, and the hash matches.
- [x] The state goes to Retrying while waiting and back to Downloading.
- [x] After 5 failures on one segment, the download is Failed with "too many retries", every connection stops and the partial file stays. Retry then completes the download.
- [x] A connection that receives nothing for 60 seconds counts as a retryable failure. Tests use a short timeout.
- [x] The temporary unexpected status error from ticket 01 is gone. Every status either maps to an error below or is retried.
- [x] On the first request, 401 fails as needs sign-in, 403 as forbidden, and 404 and 410 as not found, without retrying.

## Comments

Implemented with 7 new tests (17 cases) in the retry suite, all at the engine interface, each mutation-checked:

- one retry loop covers the probe, each segment and the whole-file download, and each segment retries from the bytes it already has, with `If-Range`;
- a reply that ends early without an error counts as a dropped connection, so ticket 01's short-reply test now expects the download to finish complete instead of failing;
- a server without range support can't resume, so its retries start the file over;
- `retry(_:)` continues a Failed download from the bytes it has, in the same engine. Ticket 06 makes that survive a restart;
- the engine configuration (retry timing, idle timeout, clock, jitter) is internal, so tests inject it and the app uses the defaults.

Status mapping applies to every request, not only the first. A refusal in the middle of a download (401, 403, 404, 410) fails it the same way until ticket 06 adds "link expired". A status with no mapping, such as 400, fails as a network error with the status in its description.
