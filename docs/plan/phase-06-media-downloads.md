# Phase 6: Media downloads

## Goal

Dowlio downloads video and audio from streaming pages and from the sites yt-dlp supports, offers real quality choices, and saves a single playable file. It refuses DRM-protected content with a clear message.

## Before you start

Phase 5. Read research §6 and §7.

## How it's built

### HLS, in `DowlioMedia`

- `M3U8Parser` follows RFC 8216. It reads master playlists (variants with `BANDWIDTH`, `RESOLUTION`, `CODECS`, plus audio and subtitle renditions) and media playlists (segments, `EXT-X-KEY`, `EXT-X-MAP`, `EXT-X-BYTERANGE`, `EXT-X-ENDLIST`). Relative URIs resolve against the playlist URL.
- `HLSDownload` reuses the engine's scheduler. Each media segment is a work unit. Up to the connection setting's number of segments download at once. Each segment retries on its own.
- `AES-128` keys are fetched once per key URI. Segments are decrypted with CommonCrypto `CCCrypt` in CBC mode, using the IV from the tag or the sequence number.
- Protection check. `METHOD=SAMPLE-AES`, `SAMPLE-AES-CTR`, or a `KEYFORMAT` for FairPlay, Widevine or PlayReady stops the download with "This video is protected and can't be downloaded."
- Size estimate. Download 3 sample segments from the chosen variant, take bytes per second, and multiply by the total duration. The panel shows it with "~".
- Live streams have no `EXT-X-ENDLIST`. The panel says "Live stream". Downloading records until the user presses Stop.
- Output. TS segments are joined in order. fMP4 segments are joined after the init segment. Then the file is remuxed to MP4 (next section).

### Merging and remuxing

- `AVRemuxer` uses AVFoundation. `AVMutableComposition` takes the video and audio tracks, and `AVAssetExportSession` with `AVAssetExportPresetPassthrough` writes MP4 without re-encoding. It handles H.264, HEVC and AAC.
- `FFmpegRemuxer` runs the bundled `ffmpeg` helper with `-c copy` for anything AVFoundation can't open, such as VP9, AV1, Opus, WebM or MKV, and for yt-dlp merges.
- The `ffmpeg` helper is built in CI from the official FFmpeg source tarball on `ffmpeg.org`, pinned by version and SHA-256. It's configured with `--disable-gpl --disable-nonfree --disable-network` and only the demuxers, muxers and parsers Dowlio needs, which keeps it small. It ships in `Dowlio.app/Contents/Helpers/ffmpeg`, signed with the app's certificate. The About window and `THIRD_PARTY_NOTICES.md` give the LGPL notice and a link to the exact source.

### yt-dlp

- `YTDLPInstaller` follows the source rule in architecture.md. It fetches the latest release from the GitHub API, downloads `yt-dlp_macos` and `SHA2-256SUMS` from that release, checks the hash, and installs to `Tools/yt-dlp` with mode 755. It records the version and the hash.
- Install only happens after the user agrees, the first time a site needs it: "This site needs yt-dlp, a free open-source tool. Dowlio downloads it from the yt-dlp project's GitHub page. About 35 MB." Settings › Downloads gets a Website support section with the version, Check for Update and Remove.
- Update checks run weekly in the background if the user turned on "Keep website support up to date". A site failure also checks for an update before showing the error, because site breakage is the usual cause.
- `YTDLPRunner` checks the binary's hash, then runs it with `--ignore-config --no-playlist --dump-single-json <url>`, a 30-second timeout and a clean environment. It decodes the JSON into `MediaInfo`: title, thumbnail, duration and formats. Each format has an ID, resolution, codecs, size, protocol, URL and HTTP headers.
- Downloading:
  - Formats with protocol `https` and a known size download through Dowlio's segmented engine with yt-dlp's headers. Separate video and audio formats download in parallel, then merge.
  - All other protocols download through yt-dlp with `-f <id> --newline --progress-template` and `--ffmpeg-location` pointing at the helper. Dowlio parses the progress lines.
- Errors map to the closed set: `unsupportedSite`, `needsSignIn`, `private`, `geoBlocked`, `protected`, `rateLimited`, `extractorBroken`, `network`. Each has one sentence of copy and a next step.
- Sign-in. Dowlio passes no cookies to yt-dlp by default. If the user shared sign-in for that site in phase 4, the cookies go through a temporary Netscape cookie file with mode 600 in a private temp folder. The file is deleted as soon as yt-dlp exits, and also at launch in case of a crash.

Phase 6 step 1 checks yt-dlp's current requirements on macOS. That includes whether YouTube extraction needs a JavaScript runtime, and whether `yt-dlp_macos` runs from a non-quarantined location without extra signing. The result goes in `docs/adr/NNNN-yt-dlp.md`.

### The Send panel with versions

The panel lists versions from HLS variants and yt-dlp formats as rows: "1080p · MP4 · H.264 + AAC · 38.2 MB". The default selection follows the preferences in Settings › Downloads: video quality (Best available, or a cap from 2160p down to 360p) and Prefer H.264 MP4. A type popup switches between Video and Audio only. "Make this my default quality" updates the preference.

## Steps

1. Spike: yt-dlp on the current macOS. Write ADR 0002.
2. Build `M3U8Parser` with tests on fixture playlists, including encrypted, fMP4, byte-range, live and DRM-tagged ones.
3. Build `HLSDownload` and the AES-128 decryption. Test it with HLS fixtures served by the test server.
4. Build `AVRemuxer`.
5. Add the CI job that builds the `ffmpeg` helper, and `FFmpegRemuxer`.
6. Build `YTDLPInstaller`, the consent prompt and the Website support settings.
7. Build `YTDLPRunner`, format mapping, both download paths and error mapping.
8. Connect HLS and yt-dlp results to the analyser and the Send panel.
9. Release `v0.4.0`.

## Done when

- A public HLS test stream downloads to an MP4 that QuickTime plays, at the chosen resolution.
- An encrypted AES-128 test stream decrypts correctly. A DRM-tagged playlist shows the protected message without downloading anything.
- On a clean install, the first yt-dlp site asks for consent, installs from GitHub, and lists formats.
- Replacing `Tools/yt-dlp` with a different file makes Dowlio refuse to run it and offer to reinstall.
- A separate video and audio download merges into one file with both tracks.
- No cookie file remains on disk after a download, a crash or a cancel.

## Out of scope

Playlists and channel downloads, subtitles, and audio conversion to other formats. They can be added after phase 8.
