# 0003: Plain HTTP downloads are allowed

Status: accepted, 2026-10-23

Dowlio turns App Transport Security off app-wide (`NSAllowsArbitraryLoads`) so it can download `http://` links, which many real mirrors and devices still serve. macOS has no per-request exception, and refusing `http://` would make Dowlio fail where a browser succeeds. Dowlio doesn't try `https://` first. It downloads the link as given and marks every plain-HTTP download "Not secure" wherever the download appears.

## Considered options

- Refuse `http://`. Rejected: users would fall back to the browser for those files.
- Try `https://` first, then fall back. Rejected by the owner in favour of the simpler rule.

## Consequences

The exception covers every request Dowlio makes, not just downloads. Code that talks to Dowlio's own services, such as yt-dlp and update checks, must use `https://` URLs and must not follow a redirect to `http://`.
