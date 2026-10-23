# 07: Restore and crash recovery

**What to build:** Unfinished downloads survive a quit or a crash. The engine can restore a download from its partial file alone, adding it as Paused when it doesn't know it. A download whose partial file was deleted starts over from the beginning. The command-line tool can resume a partial file, and Ctrl-C pauses.

**Blocked by:** 06

**Status:** resolved

- [x] Restoring a partial file the engine doesn't know adds it as Paused. Resuming completes it with a matching hash.
- [x] In-process test: drop the engine mid-download, create a new one, restore and resume, and the hash matches.
- [x] Out-of-process test: kill `dowlio-cli get` with SIGKILL mid-download, run `dowlio-cli resume` on the partial file, and the hash matches.
- [x] Ctrl-C during `dowlio-cli get` pauses and prints the partial file path.
- [x] If the partial file is missing when a download runs, it starts over in a new partial file and completes.

## Comments

The engine gains `restore(partialFile:)` and `partialFile(of:)`. Restoring a partial file the engine already has returns that download. A partial file without a readable manifest throws `RestoreError.unreadableManifest` and is left as it is.

The in-process crash test copies the partial file exactly as it is on disk while replies are held and a periodic save has recorded bytes, cancels the old download, puts the copy back and restores it in a new engine. The out-of-process test kills `dowlio-cli get` with SIGKILL as soon as the saved manifest records bytes. Ctrl-C makes `dowlio-cli` pause, print `Paused: <partial file>` and exit with 130.
