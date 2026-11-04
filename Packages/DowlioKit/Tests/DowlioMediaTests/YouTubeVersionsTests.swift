import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YouTubeVersionsTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!

    private func candidate(_ url: URL, fixture: String) async throws -> Candidate {
        let standIn = try await YTDLPStandIn.printing(fixture)
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer)) { _, _ in throw URLError(.cannotConnectToHost) }
        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: url)) { last = update }
        guard case .found(let candidates)? = last, let first = candidates.first else { throw FoundNothing() }
        return first
    }

    private struct FoundNothing: Error {}

    @Test func eachHeightUpTo1080pIsOneH264VersionPairedWithTheAACTrack() async throws {
        let video = try await candidate(watch, fixture: "video-1080p.json")

        let rows = video.versions.filter { !$0.isAudio }
        #expect(rows.map(\.height) == [1080, 720, 480, 360, 240, 144])
        #expect(rows.allSatisfy { $0.codecs == "H.264 + AAC" && $0.outputContainer == .mp4 })
        let tallest = try #require(rows.first)
        #expect(tallest.renewal == MediaRenewal(pageURL: watch, formatIDs: ["137", "140"]))
        #expect(tallest.totalBytes == Int64(77_615_175 + 4_562_922))
        #expect(tallest.isEstimatedSize == false)
        #expect(tallest.requestSizeLimit == 10_485_760)
        #expect(tallest.expiry == Date(timeIntervalSince1970: 1_793_799_947))
        #expect(tallest.userAgent?.hasPrefix("Mozilla/5.0") == true)
        guard case .media(let media) = tallest.source else { Issue.record("not media"); return }
        #expect(media.tracks.map(\.kind) == [.video, .audio])
        #expect(media.tracks.map(\.codecs) == [["avc1.640028"], ["mp4a.40.2"]])
        #expect(media.tracks.map { $0.fragments.map(\.bytes) } == [[0...77_615_174], [0...4_562_921]])
        #expect(media.tracks[0].fragments[0].url.query()?.contains("itag=137") == true)
    }

    @Test func audioOnlyIsTheAACTrackSavedAsM4A() async throws {
        let video = try await candidate(watch, fixture: "video-1080p.json")

        let audio = video.versions.filter(\.isAudio)
        #expect(audio.count == 1)
        let only = try #require(audio.first)
        #expect(only.codecs == "AAC")
        #expect(only.outputContainer == .m4a)
        #expect(only.renewal?.formatIDs == ["140"])
        #expect(only.totalBytes == 4_562_922)
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=2Vv-BfVoq4g",
        "https://m.youtube.com/watch?v=2Vv-BfVoq4g",
        "https://youtube.com/shorts/2Vv-BfVoq4g",
        "https://www.youtube.com/live/2Vv-BfVoq4g",
        "https://www.youtube.com/embed/2Vv-BfVoq4g",
        "https://youtu.be/2Vv-BfVoq4g",
        "https://music.youtube.com/watch?v=2Vv-BfVoq4g",
        "https://www.youtube-nocookie.com/embed/2Vv-BfVoq4g",
    ])
    func everyYouTubeLinkFormGoesToYTDLP(link: String) async throws {
        let video = try await candidate(URL(string: link)!, fixture: "video-1080p.json")

        #expect(video.label == "Ed Sheeran - Perfect (Official Music Video)")
        #expect(!video.versions.isEmpty)
    }

    @Test(arguments: [
        "https://www.youtube.com/",
        "https://www.youtube.com/results?search_query=perfect",
        "https://www.youtube.com/watch",
        "https://notyoutube.com/watch?v=2Vv-BfVoq4g",
        "https://youtube.com.evil.example/watch?v=2Vv-BfVoq4g",
    ])
    func otherPagesAreNotYouTubeVideos(link: String) {
        #expect(YouTubeLink(URL(string: link)!) == nil)
    }

    @Test func aYouTubeMusicLinkOpensOnAudioOnly() async throws {
        let song = try await candidate(URL(string: "https://music.youtube.com/watch?v=2Vv-BfVoq4g")!, fixture: "video-1080p.json")
        let video = try await candidate(watch, fixture: "video-1080p.json")

        #expect(song.opensAsAudio)
        #expect(!video.opensAsAudio)
    }
}
