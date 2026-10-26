import DowlioCore
import DowlioMedia
import Foundation
import Testing

struct M3U8ParserTests {
    private func fixture(_ name: String, at base: String = "https://cdn.example.com/hls/stream/master.m3u8") throws -> Playlist {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Streams/\(name)", withExtension: "m3u8"))
        return try M3U8Parser.parse(String(contentsOf: url, encoding: .utf8), base: URL(string: base)!)
    }

    @Test func aMasterPlaylistListsItsVariantsWithResolutionCodecsAndAddress() throws {
        guard case .master(let master) = try fixture("hls-master-unknown-tag") else { Issue.record("not a master"); return }

        #expect(master.variants.map(\.height) == [360, 480, 720, 1080])
        #expect(master.variants.first?.codecs == ["avc1.64001e", "mp4a.40.2"])
        #expect(master.variants.first?.bandwidth == 1_415_763)
        #expect(master.variants.first?.url == URL(string: "https://cdn.example.com/hls/stream/360p/video.m3u8"))
        #expect(master.variants.first?.audioGroup == nil)
    }

    @Test func rootRelativeAddressesAndAudioGroupsAreRead() throws {
        guard case .master(let master) = try fixture("hls-master-video-only-root-relative") else { Issue.record("not a master"); return }

        #expect(master.variants.first?.url.host() == "cdn.example.com")
        #expect(master.variants.first?.url.path().hasPrefix("/amplify_video/") == true)
        #expect(master.variants.first?.height == 2160)
        #expect(master.variants.first?.audioGroup == "audio-128000")
        #expect(master.audio.map(\.groupID).contains("audio-128000"))
        #expect(master.audio.first?.url?.path().contains("/mp4a/") == true)
    }

    @Test func aMediaPlaylistListsItsSegmentsInOrderWithTheirLengthAndEnd() throws {
        guard case .media(let media) = try fixture("hls-media-ts") else { Issue.record("not media"); return }

        #expect(media.fragments.count == 100)
        #expect(media.fragments.first == MediaFragment(url: URL(string: "https://cdn.example.com/hls/stream/fileSequence0.ts")!))
        #expect(media.initialization == nil)
        #expect(media.isComplete)
        #expect(abs(media.duration - 600) < 1)
        #expect(media.encryption == .none)
    }

    @Test func segmentsNamedLikeImagesAreStillSegments() throws {
        guard case .media(let media) = try fixture("hls-media-ts-named-jpeg") else { Issue.record("not media"); return }

        #expect(media.fragments.map(\.url.lastPathComponent).prefix(2) == ["video0.jpeg", "video1.jpeg"])
    }

    @Test func anInitSegmentAndByteRangesOfOneFileAreRead() throws {
        guard case .media(let media) = try fixture("hls-media-single-file-relative") else { Issue.record("not media"); return }

        let file = URL(string: "https://cdn.example.com/hls/stream/main.mp4")!
        #expect(media.initialization == MediaFragment(url: file, bytes: 0...718))
        #expect(media.fragments.first == MediaFragment(url: file, bytes: 719...1_508_718))
        #expect(media.fragments[1].bytes == 1_508_719...3_018_962)
        #expect(media.singleFile == file)
    }

    @Test func absoluteSingleFileByteRangesAreOneFileToo() throws {
        guard case .media(let media) = try fixture("hls-media-single-file-absolute") else { Issue.record("not media"); return }

        #expect(media.singleFile == URL(string: "https://media.gifhost.example/SampleClipName-mobile.m4s"))
    }

    @Test func separateSegmentFilesAreNotOneFile() throws {
        guard case .media(let media) = try fixture("hls-media-fmp4-root-relative") else { Issue.record("not media"); return }

        #expect(media.initialization != nil)
        #expect(media.singleFile == nil)
    }

    @Test func encryptionLivenessAndProtectionAreNoticed() throws {
        guard case .media(let aes) = try fixture("hls-media-aes128"),
              case .media(let live) = try fixture("hls-media-live"),
              case .media(let drm) = try fixture("hls-media-sample-aes")
        else { Issue.record("not media"); return }

        #expect(aes.encryption == .aes128)
        #expect(!live.isComplete)
        #expect(drm.encryption == .protected)
    }

    @Test func textThatIsntAPlaylistIsRefused() {
        #expect(throws: M3U8Parser.Error.notAPlaylist) {
            try M3U8Parser.parse("<html>nope</html>", base: URL(string: "https://a.example/x.m3u8")!)
        }
    }
}
