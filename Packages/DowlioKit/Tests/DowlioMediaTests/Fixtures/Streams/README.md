# Stream fixtures

The phase 5 spike collected these playlists and manifests on 2026-10-26. They hold no media.

## From public test streams, unchanged

| File | Source |
|---|---|
| hls-master-fmp4-renditions.m3u8 | Apple's advanced fMP4 example, `devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8` |
| hls-media-single-file-relative.m3u8 | The same example's `v5/prog_index.m3u8`, where every segment is a byte range of one relative file, `main.mp4` |
| hls-media-ts.m3u8 | The TS example's `v5/prog_index.m3u8` |
| hls-master-muxed.m3u8 | Mux test stream `test-streams.mux.dev/x36xhzz/x36xhzz.m3u8` |
| hls-master-aes128.m3u8, hls-media-aes128.m3u8 | JW Player's AES-128 test `playertest.longtailvideo.com/adaptive/oceans_aes/` |
| dash-static.mpd | Akamai `dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd` |
| dash-static-languages-and-text.mpd | Shaka demo `storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd`, with audio in four languages and text tracks |
| dash-widevine.mpd | Shaka demo `.../angel-one-widevine/dash.mpd` |
| dash-dynamic.mpd | DASH-IF live simulator `livesim2.dashif.org/livesim2/testpic_2s/Manifest.mpd` |

The spike wrote `hls-media-live.m3u8` and `hls-media-sample-aes.m3u8` by hand. The public live test stream returned an empty playlist, and testing the refusal needs no real FairPlay stream.

The public manifests keep their own hosts and comments. Tickets 11 to 14 use them to test the HLS and DASH parsers on shapes the target sites didn't show: AES-128, Widevine, live DASH and multiple languages.

## From real sites, trimmed

The spike cut each playlist to its first four segments and added `#EXT-X-ENDLIST` back. It replaced hosts, IDs, tokens and file names, and kept the tags and URI shapes.

| File | Shape it keeps |
|---|---|
| hls-master-unknown-tag.m3u8 | A tube site's master with a nonstandard `#EXT-X-TOKEN` tag, H.264 + AAC 360p to 1080p |
| hls-media-ts-named-jpeg.m3u8 | Its media playlist: MPEG-TS segments named `.jpeg` and served as `image/jpeg` |
| hls-master-video-only-root-relative.m3u8 | X: root-relative URIs, video-only variants up to 2160x3840, three AAC audio groups |
| hls-media-fmp4-root-relative.m3u8 | X: an fMP4 video playlist with a root-relative `EXT-X-MAP` and segments |
| hls-media-fmp4-audio.m3u8 | X: the matching audio playlist, which a merge test pairs with the video one |
| hls-master-cmaf-subtitles.m3u8 | Reddit: CMAF variants in two audio groups, plus a subtitles group |
| hls-media-single-file-absolute.m3u8 | A short-clip site: every segment is a byte range of one absolute file |

## Captured for the site readers

| File | Shape it keeps |
|---|---|
| hls-master-query-session.m3u8 | Bluesky, captured 2026-10-27: two H.264 variants whose URIs carry a `session_id` query, and no audio codec, because that video has no sound |
