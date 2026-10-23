# 09: File names and finished files

**What to build:** Downloads get their proper names, cleaned of anything unsafe. Name conflicts follow Keep both, Replace or Skip. Finished files carry the downloaded-from-the-internet flag naming Dowlio. Plain `http://` downloads are marked "Not secure", and the app allows them (ADR 0003).

**Blocked by:** 01

**Status:** resolved

- [x] The name comes from `Content-Disposition` (`filename*` first, then `filename`), otherwise the final URL's last path component percent-decoded, otherwise "download".
- [x] A missing extension is added from the content type when one maps.
- [x] `/`, `:`, control characters and leading dots are removed, and names are capped at 200 bytes.
- [x] The temporary file exists error from ticket 01 is gone.
- [x] Keep both saves "name 2.ext", "name 3.ext" and so on. Replace overwrites. Skip keeps the existing file and completes without moving the new one.
- [x] Finished files have the quarantine attribute with Dowlio as the agent and the source URL as the origin.
- [x] Snapshots mark every `http://` download "not secure". The app's Info.plist turns App Transport Security off.

## Comments

Implemented with 12 tests in the finished-file suite. Ticket 01's overwrite test now expects Keep both.

- `filename*` supports UTF-8 and ISO-8859-1. Other charsets fall back to `filename`.
- The 200-byte cap keeps an extension of up to 20 bytes. Keep both's " 2" suffix can take a name past 200 bytes, which is still well under the 255-byte file system limit.
- The quarantine attribute is set before the rename, so the finished file never exists without it. macOS keeps the agent name in the file's attribute, but records the origin URL in its system-wide quarantine events database, not in the file. That database is a per-user log of download URLs, the same one browsers write to. Worth a privacy decision: keep the origin URL there, or set only the agent.
- "Not secure" also applies when an `https://` link redirects to `http://`.
