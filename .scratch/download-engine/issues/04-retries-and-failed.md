# 04: Retries and Failed

**What to build:** A dropped or erroring connection is retried automatically with growing waits, and the download shows as Retrying meanwhile. A segment that fails 5 times makes the download Failed, with its partial file kept, and Retry continues it from where it stopped. Clear errors come back for links that are forbidden, missing or need sign-in.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Network errors, timeouts, 408, 429 and 5xx are retried. Other 4xx aren't.
- [ ] Delays start at 1 second, double, carry plus or minus 20 percent jitter and are capped at 30 seconds. `Retry-After` replaces the delay, up to 5 minutes. Tests inject a fast policy.
- [ ] A connection dropped after N bytes resumes its segment from the bytes it has, and the hash matches.
- [ ] The state goes to Retrying while waiting and back to Downloading.
- [ ] After 5 failures on one segment, the download is Failed with "too many retries", every connection stops and the partial file stays. Retry then completes the download.
- [ ] A connection that receives nothing for 60 seconds counts as a retryable failure. Tests use a short timeout.
- [ ] The temporary unexpected status error from ticket 01 is gone. Every status either maps to an error below or is retried.
- [ ] On the first request, 401 fails as needs sign-in, 403 as forbidden, and 404 and 410 as not found, without retrying.
