# Player fixtures

Pages that set up a common web player, written by hand on 2026-10-29 in the shape each player's documentation gives for its setup. Hosts are the test server, `{{server}}`, `{{host}}` and `{{api}}` are filled in by the test, and text is a stand-in.

| File | Shape it keeps |
|---|---|
| jwplayer-setup.html | `jwplayer(id).setup({…})` with a title, image, duration and `sources` holding an HLS playlist and two MP4 files with labels |
| jwplayer-hosted.html | A JW Player setup whose `playlist` is a hosted media address, `/v2/media/<id>` |
| jwplayer-media.json | The hosted media reply for that ID: a `playlist` item with its title, image, duration and `sources` (HLS, a 720p MP4 and an audio file) |
| videojs.html | A `<video class="video-js">` with a `data-setup` JSON holding an HLS source, and a `<video-js>` element with two `<source>` files and `res` attributes |
| plyr.html | A Plyr player whose `player.source = {…}` lists two MP4 files with a `size`, a title and a poster |
| flowplayer.html | `flowplayer(selector, { clip: { sources: […] } })` with a protocol-relative HLS playlist and an MP4 file |
| clappr.html | `new Clappr.Player({ source, poster })` with an HLS playlist |
