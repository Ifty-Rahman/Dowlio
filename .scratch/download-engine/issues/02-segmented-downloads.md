# 02: Segmented downloads

**What to build:** A file on a server that supports ranges downloads over several connections at once. By default the extra connections open after the first one starts receiving data; "all at once" is an option. Every reply is checked against what was asked for. Snapshots show each segment's progress, smoothed speed and time left.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] The segment planner (seam 2) splits a file into contiguous segments that cover it exactly, uses at most the connection setting (default 8, maximum 16), and never makes a segment smaller than 1 MiB. Table-driven tests cover many sizes and counts.
- [ ] A 64 MiB file with 8 connections downloads over 8 connections and its hash matches.
- [ ] Each connection uses its own `URLSession`.
- [ ] Every ranged request sends `Range` and `If-Range` with the validator. A 206 whose `Content-Range` doesn't match the request exactly is rejected.
- [ ] In the default mode, the test server sees one request before the others start. In "all at once" mode, it sees them start together.
- [ ] Snapshots carry per-segment start, end, received and active flags, the active connection count, speed smoothed over 5 seconds and time remaining, at most 4 times a second.
