import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NeedsSignInTests {
    private func page(_ site: Site, at path: String, requiring cookie: String, html: String = "<title>Members</title>") {
        var file = TestServer.File(data: Data(html.utf8), headers: ["Content-Type": "text/html"])
        file.requiredCookie = cookie
        site.server.serve(file, at: path)
    }

    private func refused(_ site: Site, status: Int, at path: String, type: String = "video/mp4") {
        site.server.serve(TestServer.File(data: Data(count: 10), headers: ["Content-Type": type], failFirst: .init(status: status)), at: path)
    }

    @Test func aPageThatAsksForSignInEvenWithTheBrowsersCookiesNeedsSignIn() async throws {
        let site = try await Site()
        page(site, at: "/members/watch", requiring: "session=right")

        let found = try await site.analyze("/members/watch") { $0.cookies = [Cookie(name: "session", value: "stale")] }

        #expect(found == .needsSignIn)
    }

    @Test func aPageThatRefusesWith403NeedsSignIn() async throws {
        let site = try await Site()
        refused(site, status: 403, at: "/private/watch", type: "text/html")

        #expect(try await site.analyze("/private/watch") == .needsSignIn)
    }

    @Test func aVideoThatRefusesEveryoneButItsSignedInVisitorsNeedsSignIn() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        refused(site, status: 401, at: "/media/clip.mp4")

        #expect(try await site.analyze("/watch") == .needsSignIn)
    }

    @Test func aPlaylistThatRefusesWith403NeedsSignIn() async throws {
        let site = try await Site()
        site.serve(html: "<title>Stream</title>", at: "/watch")
        refused(site, status: 403, at: "/hls/master.m3u8", type: "application/vnd.apple.mpegurl")

        let found = try await site.analyze("/watch") {
            $0.watched = [WatchedRequest(url: site.url("/hls/master.m3u8"), kind: .manifest)]
        }

        #expect(found == .needsSignIn)
    }

    @Test func otherVideosStayWhenOneIsRefused() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Two</title><video src="/media/locked.mp4"></video><video src="/media/open.mp4"></video>"#, at: "/watch")
        refused(site, status: 403, at: "/media/locked.mp4")
        site.serve(video: 90, at: "/media/open.mp4")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).map(\.source.url) == [site.url("/media/open.mp4")])
    }

    @Test func aRefusedPageIsNotPlayedInTheHiddenWindow() async throws {
        let site = try await Site()
        refused(site, status: 401, at: "/members/watch", type: "text/html")
        let engine = DownloadEngine(configuration: .fast)
        let analyzer = PageAnalyzer(lookAgain: { _ in
            Issue.record("played a refused page")
            return PlayedPage()
        }) { url, options in try await engine.inspect(url, options: options) }

        var updates: [PageAnalysis] = []
        for await update in analyzer.analyze(SentPage(url: site.url("/members/watch"))) { updates.append(update) }

        #expect(updates == [.needsSignIn])
    }

    @Test func aLinkStraightToARefusedPlaylistNeedsSignIn() async throws {
        let site = try await Site()
        refused(site, status: 403, at: "/hls/master.m3u8", type: "application/vnd.apple.mpegurl")

        #expect(try await site.analyze("/hls/master.m3u8") == .needsSignIn)
    }

    @Test func playlistsAreAskedForWithTheBrowsersCookies() async throws {
        let site = try await Site()
        site.serve(html: "<title>Stream</title>", at: "/watch")
        var playlist = TestServer.File(data: Data("#EXTM3U\n#EXTINF:4,\n/hls/0.ts\n#EXT-X-ENDLIST\n".utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
        playlist.requiredCookie = "session=abc"
        site.server.serve(playlist, at: "/hls/index.m3u8")

        let found = try await site.analyze("/watch") {
            $0.cookies = [Cookie(name: "session", value: "abc")]
            $0.watched = [WatchedRequest(url: site.url("/hls/index.m3u8"), kind: .manifest)]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
    }

    @Test func aRefusedFileThePageOnlyRequestedIsntTakenForSignIn() async throws {
        let site = try await Site()
        site.serve(html: "<title>Article</title>", at: "/article")
        refused(site, status: 403, at: "/ads/spot.mp4")

        let found = try await site.analyze("/article") {
            $0.watched = [WatchedRequest(url: site.url("/ads/spot.mp4"), kind: .file, contentType: "video/mp4")]
        }

        #expect(found == .found([]))
    }
}
