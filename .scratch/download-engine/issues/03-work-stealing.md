# 03: Work stealing

**What to build:** When a connection finishes its segment early, it takes over the second half of the largest remaining segment, so one slow segment never holds up the end of a download.

**Blocked by:** 02

**Status:** resolved

- [x] Planner tests: stealing splits the largest remaining range at its midpoint, refuses when either half would be under 1 MiB, and handles several connections finishing at once.
- [x] With one connection throttled hard on the test server, the download finishes far sooner than that connection alone would, and the snapshots show the throttled segment being split.
- [x] Hashes still match.

## Comments

Implemented with 8 planner cases (seam 2) and 2 engine tests (seam 1):

- a 32 MiB download whose last segment trickles at 1 MiB a second finishes in under 4 seconds instead of 8;
- after a split, the manifest matches the paused snapshot, its counted bytes are in the data file, and Resume asks for exactly each segment's missing part.

The progress board now owns the segment bounds, because stealing changes them mid-download. A steal takes only bytes no connection has claimed yet, and received counts still rise only after a write, so the manifest never leads the data file. The victim connection writes up to its new end and closes there; it doesn't ask the server again.

Three earlier tests expected exact request lists, which stealing extends. They now check that each planned segment is asked for once, that connections never exceed the setting, and that a restarted download asks again from each segment's first byte.
