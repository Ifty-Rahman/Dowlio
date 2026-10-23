# 02: Segmented downloads

**What to build:** A file on a server that supports ranges downloads over several connections at once. By default the extra connections open after the first one starts receiving data; "all at once" is an option. Every reply is checked against what was asked for. Snapshots show each segment's progress, smoothed speed and time left.

**Blocked by:** 01

**Status:** resolved

- [x] The segment planner (seam 2) splits a file into contiguous segments that cover it exactly, uses at most the connection setting (default 8, maximum 16), and never makes a segment smaller than 1 MiB. Table-driven tests cover many sizes and counts.
- [x] A 64 MiB file with 8 connections downloads over 8 connections and its hash matches.
- [x] Each connection uses its own `URLSession`.
- [x] Every ranged request sends `Range` and `If-Range` with the validator. A 206 whose `Content-Range` doesn't match the request exactly is rejected.
- [x] In the default mode, the test server sees one request before the others start. In "all at once" mode, it sees them start together.
- [x] Snapshots carry per-segment start, end, received and active flags, the active connection count, speed smoothed over 5 seconds and time remaining, at most 4 times a second.

## Comments

Implemented with 3 planner tests (seam 2) and 6 engine tests (seam 1). Tests that passed on first run were mutation-checked.

- "Own `URLSession` per connection" holds by construction in `Connection` and isn't observable through the engine. Ticket 10's benchmark checks the speed benefit.
- "At most 4 times a second" comes from the 250 ms reporter interval and has no test.
- New options: `RequestOptions.connections` (default 8, clamped 1 to 16) and `openExtraConnections`. `dowlio-cli get` takes `-c <connections>` and prints speed, time left and connections.
- Test server: `eTag` and `lastModified` options. One-byte bodies such as the probe reply are never held, so `holdAfterBytes: 0` holds a body before its first byte.
- Two ticket 01 tests changed to keep testing the same behaviour now that downloads split into segments: the partial-file test holds after 512 KiB, and the CLI stall test runs with `-c 1`.
