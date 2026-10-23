# Dowlio

A native macOS download manager. It finishes downloads that start in the browser, and it finds downloadable files and media on pages that have no download button.

## Workflows

**Catch downloads**:
The workflow where the Dowlio browser extension takes over a download the browser started, so it finishes in Dowlio. One such takeover is a catch.
_Avoid_: Capture, intercept, grab

**Send to Dowlio**:
The workflow where the user deliberately sends the page they're on to Dowlio, which looks for files and media on it and offers them.
_Avoid_: Send page, send to app, share

**Candidate**:
A file or media item that Send to Dowlio found on a page.
_Avoid_: Result, item, media

**Version**:
One quality or format a candidate is available in, such as 1080p MP4 or audio only.
_Avoid_: Format, variant, quality, rendition

## Downloads

**Download**:
One file the user asked for, from the moment it's added until the finished file is in its folder.
_Avoid_: Job, task, transfer, item

**Segment**:
One byte range of a download's file, fetched on its own.
_Avoid_: Chunk, part, piece

**Connection**:
One request that is currently fetching part of a segment. A download uses several connections at once.
_Avoid_: Thread, stream, socket

**Queued**:
A download waiting for its turn to start.

**Downloading**:
A download whose connections are fetching data.

**Retrying**:
A download waiting a few seconds before Dowlio tries a failed connection again, on its own.
_Avoid_: Reconnecting, error

**Paused**:
A download the user stopped. Resume continues it.
_Avoid_: Stopped, suspended

**Failed**:
A download that ran out of retries or hit an error it can't recover from. Its partial file stays, and Retry continues it.
_Avoid_: Error, broken, interrupted

**Completed**:
A download whose finished file is in its folder.
_Avoid_: Done, finished

**Resume**:
The user's action that continues a paused download.

**Retry**:
The user's action that continues a failed download.

**Cancel**:
The user's action that throws a download away. Its partial file is deleted and the download leaves the list.
_Avoid_: Stop, abort, delete

**Partial file**:
The package on disk that holds an unfinished download, next to where the finished file will go.
_Avoid_: Temp file, part file, capsule
