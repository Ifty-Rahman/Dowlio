# 05: Refusals and fallback

**What to build:** When a server refuses or resets connections, Dowlio uses fewer and remembers that host's limit, so the download carries on. When a server gives bad range replies or answers a ranged request with the whole file, the download drops to one connection and still finishes.

**Blocked by:** 02, 04

**Status:** resolved

- [x] 429, 503 and connection resets lower the host's connection limit by one, never below 1.
- [x] A host limit store, kept in memory behind an interface that phase 3 can persist, applies the learned limit to later downloads from the same host.
- [x] A test server capped at 3 parallel connections ends with the download using 3 and completing.
- [x] Range not supported no longer fails a download. Ticket 01 fails with it, and this ticket turns it into the one-connection fallback.
- [x] A wrong `Content-Range`, a `Content-Encoding` on a ranged reply, or `multipart/byteranges` drops the download to one connection, and it completes with a matching hash.

## Comments

Implemented with 7 planner cases (seam 2) and 8 engine tests (seam 1):

- 429, 503 and a reset each lower the host's limit by one; a 500 doesn't;
- a server capped at 3 parallel connections refuses 5 of 8, and the download ends at 3 and completes;
- a later download from the same host plans with the learned limit and is never refused;
- a wrong `Content-Range`, a `Content-Encoding` (on the probe reply or only on segment replies), `multipart/byteranges`, and a 200 to a range request without `If-Range` all fall back to one connection with a matching hash;
- after a fallback, the manifest holds one segment for the whole file and no validator, and the data file holds exactly the bytes it counts.

The store is `HostLimitStore`, keyed by host and port, injected through `EngineConfiguration` (in memory by default, or `DownloadEngine(hostLimits:)`). Its update is one atomic step, so refusals that land together each count once. Each download also has a connection gate. A refused connection gives its place back and lowers the gate in the same step, so a waiting connection can't slip in between.

A fallback empties the partial file and asks for the whole file without a range. Bad replies are rejected on their headers before any byte is written. URLSession fails a segment reply with an undecodable `Content-Encoding` before it hands over the response, so that error also counts as a bad range reply.

`DownloadError.rangeNotSupported` is gone, as ticket 01 planned. The fallback signal is internal.
