# 08: Cancel and disk space

**What to build:** Cancel throws a download away completely. Before downloading, Dowlio reserves the full file size on disk, so a file that can't fit fails at once with "Not enough space". A destination that can't be written to fails with a clear error.

**Blocked by:** 01

**Status:** resolved

- [x] Cancel stops every connection, deletes the partial file and ends the snapshot stream with a cancelled event. The download no longer exists in the engine.
- [x] When the size is known, the data file is reserved at full size before the first byte. Tests check it on a small disk image or with an injected reservation failure.
- [x] A reservation that fails ends in Failed with not enough space, before any data is requested.
- [x] A read-only destination folder ends in Failed with destination not writable.

## Comments

Implemented with 4 tests in the engine suite. Cancel waits for the download to stop, deletes the partial file, sends a last Cancelled snapshot and forgets the download. Cancel on a Completed download does nothing. The probe now reports what it learned, and the whole-file request goes out only after the partial file is reserved. The disk-full test mounts an 8 MB HFS+ disk image with hdiutil, so it runs out of space for real.

Not covered by a test: Cancel on a Failed download also deletes its partial file, through the same path.
