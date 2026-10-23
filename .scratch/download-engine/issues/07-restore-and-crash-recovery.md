# 07: Restore and crash recovery

**What to build:** Unfinished downloads survive a quit or a crash. The engine can restore a download from its partial file alone, adding it as Paused when it doesn't know it. A download whose partial file was deleted starts over from the beginning. The command-line tool can resume a partial file, and Ctrl-C pauses.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] Restoring a partial file the engine doesn't know adds it as Paused. Resuming completes it with a matching hash.
- [ ] In-process test: drop the engine mid-download, create a new one, restore and resume, and the hash matches.
- [ ] Out-of-process test: kill `dowlio-cli get` with SIGKILL mid-download, run `dowlio-cli resume` on the partial file, and the hash matches.
- [ ] Ctrl-C during `dowlio-cli get` pauses and prints the partial file path.
- [ ] If the partial file is missing when a download runs, it starts over in a new partial file and completes.
