# Reader fixtures

Trimmed replies from the endpoints the site readers call. Text, names, IDs and hosts are `.example` stand-ins. Each keeps the fields and nesting its reader reads.

| File | Source | Shape it keeps |
|---|---|---|
| x-tweet-result.json | X's `cdn.syndication.twimg.com/tweet-result`, captured 2026-10-27 | One post with one video: its text, author, thumbnail and length, one HLS playlist and four H.264 MP4 files from 320x568 to 1080x1920 with their bitrates |
