# 08: Cancel and disk space

**What to build:** Cancel throws a download away completely. Before downloading, Dowlio reserves the full file size on disk, so a file that can't fit fails at once with "Not enough space". A destination that can't be written to fails with a clear error.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Cancel stops every connection, deletes the partial file and ends the snapshot stream with a cancelled event. The download no longer exists in the engine.
- [ ] When the size is known, the data file is reserved at full size before the first byte. Tests check it on a small disk image or with an injected reservation failure.
- [ ] A reservation that fails ends in Failed with not enough space, before any data is requested.
- [ ] A read-only destination folder ends in Failed with destination not writable.
