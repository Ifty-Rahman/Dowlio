# 03: Work stealing

**What to build:** When a connection finishes its segment early, it takes over the second half of the largest remaining segment, so one slow segment never holds up the end of a download.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Planner tests: stealing splits the largest remaining range at its midpoint, refuses when either half would be under 1 MiB, and handles several connections finishing at once.
- [ ] With one connection throttled hard on the test server, the download finishes far sooner than that connection alone would, and the snapshots show the throttled segment being split.
- [ ] Hashes still match.
