import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LookAgainTests {
    private final class Plays: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [URL] = []
        var count: Int { lock.withLock { pages.count } }
        func record(_ page: SentPage) { lock.withLock { pages.append(page.url) } }
    }

    private func analyzer(
        on site: Site, plays: Plays, finding media: [WatchedRequest], title: String? = nil, userAgent: String? = nil
    ) -> PageAnalyzer {
        let engine = DownloadEngine(configuration: .fast)
        return PageAnalyzer(lookAgain: { page in
            plays.record(page)
            return PlayedPage(title: title, media: media, userAgent: userAgent)
        }) { url, options in try await engine.inspect(url, options: options) }
    }

    private func updates(_ stream: AsyncStream<PageAnalysis>) async -> [PageAnalysis] {
        var all: [PageAnalysis] = []
        for await update in stream { all.append(update) }
        return all
    }

    @Test func aPageWhoseQuickStepsFindNothingIsPlayedAndWhatItLoadsIsOffered() async throws {
        let site = try await Site()
        site.serve(html: "<title>Hidden player</title><div id=player></div>", at: "/watch")
        site.serve(video: 4000, at: "/hidden/clip.mp4")
        let plays = Plays()
        let analyzer = analyzer(on: site, plays: plays, finding: [WatchedRequest(url: site.url("/hidden/clip.mp4"), kind: .file)], title: "Hidden clip")

        let updates = await updates(analyzer.analyze(SentPage(url: site.url("/watch"))))

        #expect(updates.map(\.withoutExtractedAudio) == [.playing, .found([Candidate(
            label: "Hidden clip",
            versions: [Version(source: .file(site.url("/hidden/clip.mp4")), contentType: "video/mp4", totalBytes: 4000)]
        )])])
        #expect(plays.count == 1)
    }

    @Test func whatAPlayedPageLoadsIsAskedForAsThePlayerAskedForIt() async throws {
        let site = try await Site()
        site.serve(html: "<title>Embed</title>", at: "/watch")
        site.server.serve(TestServer.File(
            data: Data(repeating: 7, count: 4000), headers: ["Content-Type": "video/mp4"], requiredUserAgent: "HiddenPlayer/1"
        ), at: "/hidden/clip.mp4")
        let analyzer = analyzer(
            on: site, plays: Plays(), finding: [WatchedRequest(url: site.url("/hidden/clip.mp4"), kind: .file)], userAgent: "HiddenPlayer/1"
        )

        let updates = await updates(analyzer.analyze(SentPage(url: site.url("/watch"))))

        guard case .found(let candidates) = updates.last else { Issue.record("not found: \(updates)"); return }
        let versions = try #require(candidates.first?.versions)
        #expect(versions.first?.totalBytes == 4000)
        #expect(versions.allSatisfy { $0.userAgent == "HiddenPlayer/1" })
    }

    @Test func aPageWithVideoIsNotPlayed() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 50, at: "/media/clip.mp4")
        let plays = Plays()

        let updates = await updates(analyzer(on: site, plays: plays, finding: []).analyze(SentPage(url: site.url("/watch"))))

        #expect(!updates.contains(.playing))
        #expect(plays.count == 0)
    }

    @Test func playingAPageThatLoadsNothingFindsNothing() async throws {
        let site = try await Site()
        site.serve(html: "<p>Just words</p>", at: "/article")

        let updates = await updates(analyzer(on: site, plays: Plays(), finding: []).analyze(SentPage(url: site.url("/article"))))

        #expect(updates == [.playing, .found([])])
    }

    @Test func lookingAgainPlaysThePageEvenAfterItsVideoWasFound() async throws {
        let site = try await Site()
        site.serve(html: "<title>Stream page</title>", at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            /hls/0.ts
            #EXT-X-ENDLIST
            """, at: "/hls/index.m3u8")
        let plays = Plays()
        let analyzer = analyzer(on: site, plays: plays, finding: [WatchedRequest(url: site.url("/hls/index.m3u8"), kind: .manifest)])

        let updates = await updates(analyzer.lookAgain(SentPage(url: site.url("/watch"), title: "Stream page")))

        guard case .found(let candidates) = updates.last else { Issue.record("not found: \(updates)"); return }
        #expect(updates.first == .playing)
        #expect(candidates.map(\.label) == ["Stream page"])
        #expect(candidates.first?.duration == 4)
        #expect(plays.count == 1)
    }

    @Test func anAnalyserThatCantPlayPagesGoesStraightToNothingFound() async throws {
        let site = try await Site()
        site.serve(html: "<p>Just words</p>", at: "/article")

        #expect(try await site.analyze("/article") == .found([]))
        #expect(await updates(site.analyzer.lookAgain(SentPage(url: site.url("/article")))) == [.found([])])
    }
}
