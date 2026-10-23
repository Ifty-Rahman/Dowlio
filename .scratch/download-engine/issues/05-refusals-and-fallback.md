# 05: Refusals and fallback

**What to build:** When a server refuses or resets connections, Dowlio uses fewer and remembers that host's limit, so the download carries on. When a server gives bad range replies or answers a ranged request with the whole file, the download drops to one connection and still finishes.

**Blocked by:** 02, 04

**Status:** ready-for-agent

- [ ] 429, 503 and connection resets lower the host's connection limit by one, never below 1.
- [ ] A host limit store, kept in memory behind an interface that phase 3 can persist, applies the learned limit to later downloads from the same host.
- [ ] A test server capped at 3 parallel connections ends with the download using 3 and completing.
- [ ] Range not supported no longer fails a download. Ticket 01 fails with it, and this ticket turns it into the one-connection fallback.
- [ ] A wrong `Content-Range`, a `Content-Encoding` on a ranged reply, or `multipart/byteranges` drops the download to one connection, and it completes with a matching hash.
