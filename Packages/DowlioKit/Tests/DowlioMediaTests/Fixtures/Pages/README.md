# Page fixtures

The phase 5 spike trimmed these pages on 2026-10-26. Each keeps only the structure the analyser reads, with text, IDs and hosts swapped for `.example` stand-ins and signatures taken out.

| File | Shape it keeps |
|---|---|
| tube-progressive.html | A tube site's video page: Open Graph tags, a JSON-LD `VideoObject` whose `contentUrl` answers 403, a `<video>` with no source, and download links for 240p to 720p in H.264 and AV1 with their sizes in the link text |
| instagram-reel.html | An Instagram reel's embedded JSON at its real nesting path, with `video_versions` (720p H.264 progressive) and `video_dash_manifest` (VP9 video and HE-AAC audio) |
