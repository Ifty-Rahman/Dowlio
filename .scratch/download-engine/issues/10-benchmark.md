# 10: Benchmark

**What to build:** Proof that segmenting is faster and that one session per connection is the right choice, measured on a real CDN, recorded in a benchmarks document.

**Blocked by:** 03, 05

**Status:** ready-for-human

- [ ] Download one large public file from a major CDN with 1, 4, 8 and 16 connections. Record times and speeds.
- [ ] Repeat with one shared session against one session per connection.
- [ ] Record the Mac, network, date and file in the benchmarks document.
- [ ] If one shared session wins, write an ADR and open a ticket to switch.
