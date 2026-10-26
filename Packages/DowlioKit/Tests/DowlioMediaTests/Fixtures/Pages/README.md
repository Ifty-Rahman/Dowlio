# Page fixtures

The phase 5 spike trimmed these pages on 2026-10-26. Each keeps only the structure the analyser reads. The spike swapped text, IDs and hosts for `.example` stand-ins and took out signatures. It kept the sites' element IDs, path shapes and query parameter names, such as Meta's `oe` and `oh`, because readers may depend on them.

| File | Shape it keeps |
|---|---|
| tube-download-links.html | A tube site's video page: Open Graph tags, a JSON-LD `VideoObject` whose `contentUrl` answers 403, a `<video>` with no source, and download links for 240p to 720p in both H.264 and AV1, with each file's size in the link text |
| instagram-reel.html | An Instagram reel's embedded JSON at its real nesting path. `video_versions` lists three entries that share one 720p H.264 URL. `video_dash_manifest` has every VP9 quality from 240p to 1080p, where 240p to 720p all declare 720x1280, plus HE-AAC audio |
| facebook-reel.html | A Facebook reel's embedded JSON at its real nesting path, under `videoDeliveryResponseResult`. `progressive_urls` holds the SD and HD H.264 files. `dash_manifests` has every AV1 quality from 360p to 1080p, where 480p to 720p all declare 720x720, plus HE-AAC audio |
