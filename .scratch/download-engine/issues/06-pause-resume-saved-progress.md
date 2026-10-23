# 06: Pause, resume and saved progress

**What to build:** The user can pause a download and resume it later without losing bytes. Progress is saved about once a second in a way a crash can't corrupt. A resumed download asks for the original link again, falls back to the last working link, and keeps its segments only if the server still has the same file. A file that changed on the server restarts from zero. Snapshots say whether a download can resume.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Pause stops every connection and saves the manifest. Resume fetches only the missing bytes, and the hash matches.
- [ ] The manifest holds format version, identifier, original and final URLs, validator, size, planned name, connection setting, referrer, user agent and each segment's start, end and received. It never holds cookies.
- [ ] The data file is flushed before each manifest save, and the manifest is written atomically about once a second and on every state change.
- [ ] Resume requests the original URL. If it returns 403, 404 or 410, the saved final URL is tried. If both fail, the download is Failed with link expired.
- [ ] A validator mismatch on resume restarts from zero. A 200 to a ranged request restarts from zero once. A second change in a row fails with server changed file.
- [ ] Without a strong validator the download still segments, but a resume starts over.
- [ ] Snapshots carry "can resume", false for servers without range support or without a known size.
