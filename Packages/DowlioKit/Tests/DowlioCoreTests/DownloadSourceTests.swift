import DowlioCore
import Foundation
import Testing

struct DownloadSourceTests {
    private let clip = URL(string: "https://cdn.example/clip.mp4")!

    @Test func aMediaSourceNeedsATrack() {
        #expect(throws: MediaSource.Error.noTracks) { try MediaSource(tracks: []) }
    }

    @Test func everyTrackNeedsAFragment() {
        let empty = MediaTrack(kind: .audio, fragments: [])

        #expect(throws: MediaSource.Error.trackWithoutFragments) {
            try MediaSource(tracks: [MediaTrack(kind: .video, fragments: [MediaFragment(url: clip)]), empty])
        }
    }

    @Test func aSavedMediaSourceWithNoTracksCantBeRead() {
        let saved = Data(#"{"tracks":[]}"#.utf8)

        #expect(throws: MediaSource.Error.noTracks) { try JSONDecoder().decode(MediaSource.self, from: saved) }
    }

    @Test func aMediaSourceKeepsItsTracksFragmentsAndByteRanges() throws {
        let video = MediaTrack(
            kind: .video,
            initialization: MediaFragment(url: clip, bytes: 0...900),
            fragments: [MediaFragment(url: clip, bytes: 1197...109_759), MediaFragment(url: clip, bytes: 109_760...215_000)]
        )
        let audio = MediaTrack(kind: .audio, fragments: [MediaFragment(url: URL(string: "https://cdn.example/audio.m4a")!)])

        let source = try MediaSource(tracks: [video, audio])
        let read = try JSONDecoder().decode(MediaSource.self, from: JSONEncoder().encode(source))

        #expect(read.tracks == [video, audio])
        #expect(DownloadSource.media(read).url == clip)
    }
}
