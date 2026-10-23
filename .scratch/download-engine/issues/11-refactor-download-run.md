# 11: Split the download run and tidy the engine code

**What to build:** No behaviour changes. The code review of phase 2 found the engine harder to change than it needs to be. This ticket splits the download run into the parts the spec names and removes duplicated code, so phase 3 and later tickets touch one small part at a time. Every existing test must pass unchanged, apart from moving shared helpers.

**Blocked by:** 01 to 09 (done), and the phase 2 review fixes

**Status:** ready-for-agent

- [ ] `DownloadRun.swift` (over 800 lines) is split so each part changes for one reason: probing, planning the layout, receiving whole and segmented bodies, retry handling, progress reporting, saving the manifest, and finishing. The download run itself only sequences them.
- [ ] `Prepared` and `RunState` get names that say what they hold, or merge if one is the other plus a connection.
- [ ] One helper parses a 200 reply's size and headers. It's used by the probe and by the fallback, which each parse it today.
- [ ] One helper checks a short read. It's used by the whole-body and the segment paths.
- [ ] One helper splits a file name into base and extension. It's used by `FileNaming` and the "Keep both" numbering in `PartialFile`.
- [ ] Code that switches on `DownloadState` in the engine and the download run uses properties on `DownloadState` instead, such as `isTerminal`.
- [ ] Shared test fixtures move into `DowlioTestSupport`: the held-download starter used by the pause and restore tests, the partial file lookup used by the restore and command-line tests, and `EngineConfiguration.fast`.
- [ ] The command-line tool's `Latest` actor is removed. The newest snapshot is held in the loop that prints it.
- [ ] The test helper `engine.finished(id)` is renamed to match `GLOSSARY.md`, which has no "finished" state, for example `engine.completedOrFailed(id)`.
- [ ] The full suite passes 10 runs in a row, and `./scripts/test.sh` exits 0.

## Comments

Opened from the phase 2 code review (2026-10-23). The review's other findings are fixed directly on `phase-2-download-engine`. This ticket holds only the refactors, so they land as a change with no behaviour difference.
