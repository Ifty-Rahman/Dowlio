import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ChaptersAndCoverTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=plN7JMbadRg")!

    private func candidate(_ fixture: String, decodesAV1: Bool = true) async throws -> Candidate {
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

    private func extras(_ version: Version?) -> MediaExtras? {
        guard case .media(let media)? = version?.source else { return nil }
        return media.extras
    }

    @Test func aVideosChaptersAndCoverArtGoIntoItsMP4() async throws {
        let video = try await candidate("video-subtitles-chapters.json")

        let mp4 = extras(video.versions.first { !$0.isAudio && $0.outputContainer == .mp4 })
        #expect(mp4?.chapters.count == 22)
        #expect(mp4?.chapters.first == MediaExtras.Chapter(start: 0, end: 172, title: "The store challenge begins"))
        #expect(mp4?.coverArt == URL(string: "https://i.ytimg.com/vi/plN7JMbadRg/maxresdefault.jpg"))
    }

    @Test func audioGetsCoverArtButNoChapters() async throws {
        let video = try await candidate("video-subtitles-chapters.json")

        let audio = extras(video.versions.first(where: \.isAudio))
        #expect(audio?.coverArt != nil)
        #expect(audio?.chapters.isEmpty == true)
    }

    @Test func aWebMGetsChaptersButNoCoverArt() async throws {
        let video = try await candidate("video-4k.json", decodesAV1: false)

        let webm = video.versions.first { $0.outputContainer == .webm }
        #expect(webm != nil)
        #expect(extras(webm)?.coverArt == nil)
    }

    @Test func aJPEGThumbnailIsUsedAsItIs() async throws {
        let video = try await candidate("video-1080p.json")

        #expect(extras(video.versions.first)?.coverArt == URL(string: "https://i.ytimg.com/vi/2Vv-BfVoq4g/hqdefault.jpg"))
    }
}
