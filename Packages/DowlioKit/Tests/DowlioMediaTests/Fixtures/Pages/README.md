# Page fixtures

The phase 5 spike trimmed these pages on 2026-10-26. Each keeps only the structure the analyser reads. The spike swapped text, IDs and hosts for `.example` stand-ins and took out signatures. It kept the sites' element IDs, path shapes and query parameter names, such as Meta's `oe` and `oh`, because readers may depend on them.

| File | Shape it keeps |
|---|---|
| tube-download-links.html | A tube site's video page: Open Graph tags, a JSON-LD `VideoObject` whose `contentUrl` answers 403, a `<video>` with no source, and download links for 240p to 720p in both H.264 and AV1, with each file's size in the link text |
| instagram-reel.html | An Instagram reel's embedded JSON at its real nesting path. `video_versions` lists three entries that share one 720p H.264 URL. `video_dash_manifest` has every VP9 quality from 240p to 1080p, where 240p to 720p all declare 720x1280, plus HE-AAC audio |
| facebook-reel.html | A Facebook reel's embedded JSON at its real nesting path, under `videoDeliveryResponseResult`. `progressive_urls` holds the SD and HD H.264 files. `dash_manifests` has every AV1 quality from 360p to 1080p, where 480p to 720p all declare 720x720, plus HE-AAC audio |
| script-escaped-addresses.html | Written by hand on 2026-10-29 in the shapes tube sites use: a player's `data-` attribute holding HTML-escaped JSON with an `hlsUrl`, and inline script with a `video_url` written with `\/`, an address written with `/`, a percent-encoded address and a preroll ad from another host. `{{server}}`, `{{escaped}}` and `{{other}}` are filled in by the test |
| script-packed-player.html | A JW Player setup packed with the `eval(function(p,a,c,k,e,d)…)` packer, made on 2026-10-29 from a one-line setup whose `sources` list a root-relative HLS master |
| facebook-reel-legacy.html | A Facebook reel page as a plain request without a browser gets it, captured 2026-10-29 and trimmed, with its addresses and ID changed to stand-ins. The video sits under `playback_video` with `videoDeliveryLegacyFields`: the full AV1 `dash_manifest_xml_string` (360p to 1080p and audio), and the SD and HD progressive files in `browser_native_sd_url` and `browser_native_hd_url`. The newer `videoDeliveryResponseFragment` is empty |
| directory-apache.html | An Apache "Index of" page, trimmed on 2026-11-06 from a public file server's season folder: a Parent Directory link, two 720p `.mkv` episodes, a `.srt` file and a `.flac`, each linked by a bare file name |
| directory-h5ai.html | An h5ai index's no-script table, trimmed on 2026-11-06 from the same kind of server: a `..` Parent Directory link, two `.avi` episodes linked by root-relative percent-encoded paths, and a subfolder |
