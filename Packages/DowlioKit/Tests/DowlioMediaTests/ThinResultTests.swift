import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ThinResultTests {
    private final class Plays: @unchecked Sendable {
        private let lock = NSLock()
        private var played = 0
        var count: Int { lock.withLock { played } }
        func record() { lock.withLock { played += 1 } }
    }

    private func site(
        readers: (TestServer) -> [any SiteReader] = { _ in [] }, lookingFor limit: Duration = .seconds(15),
        playing: @escaping @Sendable (TestServer) async -> PlayedPage
    ) async throws -> (Site, Plays) {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let plays = Plays()
        let analyzer = PageAnalyzer(
            lookAgain: { _ in
                plays.record()
                return await playing(server)
            },
            lookingFor: limit, readers: readers(server), readerFailed: { _ in }
        ) { url, options in try await engine.inspect(url, options: options) }
        return (Site(server: server, analyzer: analyzer), plays)
    }

    private func updates(_ site: Site, _ path: String, page: (inout SentPage) -> Void = { _ in }) async -> [PageAnalysis] {
        var sent = SentPage(url: site.url(path))
        page(&sent)
        var all: [PageAnalysis] = []
        for await update in site.analyzer.analyze(sent) { all.append(update.withoutExtractedAudio) }
        return all
    }

    private func serveStream(on site: Site) {
        site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
            1080p.m3u8
            """, at: "/hls/master.m3u8")
        site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "seg"), at: "/hls/1080p.m3u8")
        for index in 0..<2 { site.serve(video: 100_000, type: "video/mp2t", at: "/hls/seg\(index).ts") }
    }

    @Test func aPastedLinkWithOneVideoFileShowsItThenAddsWhatLookAgainFinds() async throws {
        let (site, plays) = try await site { server in
            PlayedPage(media: [
                WatchedRequest(url: server.url(for: "/hls/master.m3u8"), kind: .manifest),
                WatchedRequest(url: server.url(for: "/media/clip.mp4"), kind: .file),
            ])
        }
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 2_000_000, at: "/media/clip.mp4")
        serveStream(on: site)

        let updates = await updates(site, "/watch")

        #expect(plays.count == 1)
        let shown = updates.compactMap { if case .checkingForMore(let rows) = $0 { rows } else { nil } }
        #expect(shown.last?.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["clip.mp4"])
        guard case .found(let candidates) = updates.last else { Issue.record("not found: \(updates)"); return }
        #expect(candidates.count == 1)
        #expect(candidates.first?.versions.map(\.source.url.lastPathComponent).sorted() == ["clip.mp4", "seg0.ts"])
    }

    @Test func aPastedLinkWithTwoVideoFilesIsNotThin() async throws {
        let (site, plays) = try await site { _ in PlayedPage() }
        site.serve(html: #"<title>Clip</title><video><source src="/media/360.mp4"><source src="/media/720.mp4"></video>"#, at: "/watch")
        site.serve(video: 1_000_000, at: "/media/360.mp4")
        site.serve(video: 2_000_000, at: "/media/720.mp4")

        let updates = await updates(site, "/watch")

        #expect(plays.count == 0)
        #expect(!updates.contains { if case .checkingForMore = $0 { true } else { false } })
    }

    @Test func aSentPageWithDataFromDowlioConnectIsNotThin() async throws {
        let (site, plays) = try await site { _ in PlayedPage() }
        site.serve(html: "<title>Clip</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/media/clip.mp4")

        _ = await updates(site, "/watch") {
            $0.throughDowlioConnect = true
            $0.watched = [WatchedRequest(url: site.url("/media/clip.mp4"), kind: .file)]
        }

        #expect(plays.count == 0)
    }

    @Test func aSentPageWhoseScanAndWatchedRequestsAreEmptyCountsAsPasted() async throws {
        let (site, plays) = try await site { _ in PlayedPage() }
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 2_000_000, at: "/media/clip.mp4")

        let updates = await updates(site, "/watch") { $0.throughDowlioConnect = true }

        #expect(plays.count == 1)
        guard case .found(let candidates) = updates.last else { Issue.record("not found: \(updates)"); return }
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["clip.mp4"])
    }

    @Test func aSiteReaderThatFoundNothingMakesTheResultThin() async throws {
        let (site, plays) = try await site(readers: { _ in [EmptyReader()] }) { _ in PlayedPage() }
        site.serve(html: #"<title>Post</title><video src="/media/a.mp4"></video><video src="/media/b.mp4"></video>"#, at: "/post/1")
        site.serve(video: 2_000_000, at: "/media/a.mp4")
        site.serve(video: 3_000_000, at: "/media/b.mp4")

        _ = await updates(site, "/post/1")

        #expect(plays.count == 1)
    }

    @Test func lookAgainOnAThinResultStopsAtTheTimeLimitAndKeepsTheRows() async throws {
        let (site, _) = try await site(lookingFor: .milliseconds(500)) { _ in
            try? await Task.sleep(for: .seconds(30))
            return PlayedPage()
        }
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 2_000_000, at: "/media/clip.mp4")
        let start = ContinuousClock.now

        let updates = await updates(site, "/watch")

        #expect(ContinuousClock.now - start < .seconds(10))
        guard case .found(let candidates) = updates.last else { Issue.record("not found: \(updates)"); return }
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["clip.mp4"])
    }
}

private struct EmptyReader: SiteReader {
    var name: String { "Empty" }
    func recognises(_ page: URL) -> Bool { page.path.hasPrefix("/post/") }
    func post(in page: URL) -> String? { nil }
    func read(_ page: SitePage) async throws -> [SiteVideo] { [] }
}
