# Sent page fixtures

Pages as Dowlio Connect sends them, trimmed from the debug record of a sent page (`~/Library/Logs/Dowlio/last-sent-page.json`). Each file holds the page's players, scan and watched requests, the page's HTML, and every file the test server serves for it. `{{server}}` is replaced with the test server's address. Text, IDs and signatures are stand-ins.

| File | Source | Shape it keeps |
|---|---|---|
| tube-hls-av1.json | The tube site record of 2026-10-28, cut down to 240p and 360p | A player whose Label is its controls' text. H.264 and AV1 download links. An AV1 HLS master whose folder name lists every resolution. A copy of one of its media playlists at another address. Watched init files and a fragment |
