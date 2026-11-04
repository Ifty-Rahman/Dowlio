import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YouTubeHighResolutionTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    private func candidate(_ fixture: String, decodesAV1: Bool) async throws -> Candidate {
        let standIn = try await YTDLPStandIn.printing(fixture)
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer), decodesAV1: decodesAV1) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: watch)) { last = update }
        guard case .found(let candidates)? = last, let first = candidates.first else { throw FoundNothing() }
        return first
    }

    private struct FoundNothing: Error {}

    private func row(_ height: Int, in video: Candidate) throws -> Version {
        try #require(video.versions.first { $0.height == height && !$0.isAudio })
    }

    @Test func aboveTenEightyAMacThatDecodesAV1GetsAV1InMP4WithAAC() async throws {
        let video = try await candidate("video-4k.json", decodesAV1: true)

        #expect(video.versions.filter { !$0.isAudio }.compactMap(\.height) == [2160, 1440, 1080, 720, 480, 360, 240, 144])
        let tallest = try row(2160, in: video)
        #expect(tallest.codecs == "AV1 + AAC")
        #expect(tallest.outputContainer == .mp4)
        #expect(tallest.renewal?.formatIDs == ["401", "140"])
        #expect(try row(1080, in: video).codecs == "H.264 + AAC")
    }

    @Test func aboveTenEightyAnOlderMacGetsVP9InWebMWithOpus() async throws {
        let video = try await candidate("video-4k.json", decodesAV1: false)

        let tallest = try row(2160, in: video)
        #expect(tallest.codecs == "VP9 + Opus")
        #expect(tallest.outputContainer == .webm)
        #expect(tallest.renewal?.formatIDs == ["315", "251"])
        guard case .media(let media) = tallest.source else { Issue.record("not media"); return }
        #expect(media.tracks.map(\.codecs) == [["vp9"], ["opus"]])
        #expect(try row(1080, in: video).outputContainer == .mp4)
    }

    @Test func sdrIsUsedWheneverItExistsAndAnHDROnlyHeightIsMarkedHDR() async throws {
        let video = try await candidate("derived-video-hdr-only-2160.json", decodesAV1: true)

        let sdr = try row(1440, in: video)
        #expect(!sdr.isHDR)
        #expect(sdr.renewal?.formatIDs.first == "308")
        let hdr = try row(2160, in: video)
        #expect(hdr.isHDR)
        #expect(hdr.renewal?.formatIDs.first == "701")
        #expect(video.versions.filter { $0.isHDR }.count == 1)
    }

    @Test func aDubbedVideoPairsTheOriginalAudioAndListsEachOtherLanguageAsItsOwnAudioRow() async throws {
        let video = try await candidate("video-dubbed.json", decodesAV1: false)

        let rows = video.versions.filter { !$0.isAudio }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.renewal?.formatIDs.last == "140-20" || $0.renewal?.formatIDs.last == "251-20" })
        let audio = video.versions.filter(\.isAudio)
        #expect(audio.first?.renewal?.formatIDs == ["140-20"])
        #expect(audio.first?.language == nil)
        let dubs = audio.dropFirst()
        #expect(dubs.count == 20)
        #expect(dubs.allSatisfy { $0.codecs == "AAC" && $0.outputContainer == .m4a })
        let german = Locale.current.localizedString(forLanguageCode: "de")
        #expect(dubs.contains { $0.language == german && $0.renewal?.formatIDs == ["140-1"] })
    }

    @Test func surroundAudioAndStoryboardsAreLeftOut() async throws {
        let video = try await candidate("video-4k.json", decodesAV1: true)

        let ids = video.versions.flatMap { $0.renewal?.formatIDs ?? [] }
        #expect(!ids.contains { ["256", "258", "380", "328", "773"].contains($0) })
        #expect(!ids.contains { $0.hasPrefix("sb") })
    }
}
