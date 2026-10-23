# 09: File names and finished files

**What to build:** Downloads get their proper names, cleaned of anything unsafe. Name conflicts follow Keep both, Replace or Skip. Finished files carry the downloaded-from-the-internet flag naming Dowlio. Plain `http://` downloads are marked "Not secure", and the app allows them (ADR 0003).

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] The name comes from `Content-Disposition` (`filename*` first, then `filename`), otherwise the final URL's last path component percent-decoded, otherwise "download".
- [ ] A missing extension is added from the content type when one maps.
- [ ] `/`, `:`, control characters and leading dots are removed, and names are capped at 200 bytes.
- [ ] The temporary file exists error from ticket 01 is gone.
- [ ] Keep both saves "name 2.ext", "name 3.ext" and so on. Replace overwrites. Skip keeps the existing file and completes without moving the new one.
- [ ] Finished files have the quarantine attribute with Dowlio as the agent and the source URL as the origin.
- [ ] Snapshots mark every `http://` download "not secure". The app's Info.plist turns App Transport Security off.
