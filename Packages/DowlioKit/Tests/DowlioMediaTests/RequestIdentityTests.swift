import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RequestIdentityTests {
    static let identity = BrowserIdentity(userAgent: "WebKitTest/1", languages: ["en-GB", "bn-BD"])

    private func site(readers: (TestServer) -> [any SiteReader] = { _ in [] }) async throws -> Site {
        let server = try await TestServer()
        let engine = DownloadEngine(identity: { Self.identity })
        let analyzer = PageAnalyzer(identity: Self.identity, readers: readers(server)) { url, options in
            try await engine.inspect(url, options: options)
        }
        return Site(server: server, analyzer: analyzer)
    }

    private func servePlayerPage(on site: Site) {
        site.serve(html: """
            <title>Clip</title>
            <video src="/media/clip.mp4"></video>
            <video><source src="/hls/master.m3u8" type="application/x-mpegURL"></video>
            """, at: "/watch")
        site.serve(video: 2_000_000, at: "/media/clip.mp4")
        site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
            720p.m3u8
            """, at: "/hls/master.m3u8")
        site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 6, named: "seg"), at: "/hls/720p.m3u8")
        for index in 0..<6 { site.serve(video: 100_000, type: "video/mp2t", at: "/hls/seg\(index).ts") }
    }

    @Test func everyRequestForAPastedLinkCarriesOneUserAgentAndTheSystemsLanguages() async throws {
        let site = try await site()
        servePlayerPage(on: site)

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        let requests = site.server.requests
        #expect(requests.count > 3)
        #expect(requests.allSatisfy { $0.headers["user-agent"] == "WebKitTest/1" })
        #expect(requests.allSatisfy { $0.headers["accept-language"] == "en-GB,bn-BD;q=0.9" })
        #expect(candidates.flatMap(\.versions).allSatisfy { $0.userAgent == "WebKitTest/1" })
    }

    @Test func aSentPageKeepsTheBrowsersUserAgent() async throws {
        let site = try await site()
        servePlayerPage(on: site)

        let found = try await site.analyze("/watch") { $0.userAgent = "Browser/2" }

        guard case .found = found else { Issue.record("not found: \(found)"); return }
        #expect(site.server.requests.allSatisfy { $0.headers["user-agent"] == "Browser/2" })
    }

    @Test func aReadersOwnRefererOriginAndUserAgentGoWithItsMedia() async throws {
        let site = try await site { server in
            [RulesReader(video: SiteVideo(
                label: "Post",
                versions: [Version(source: .file(server.url(for: "/media/clip.mp4")), contentType: "video/mp4", height: 720)],
                streams: [server.url(for: "/hls/master.m3u8")],
                rules: RequestRules(referrer: URL(string: "https://player.example/embed/1"), origin: "https://player.example", userAgent: "Reader/3")
            ))]
        }
        servePlayerPage(on: site)

        let found = try await site.analyze("/post/1")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let media = site.server.requests.filter { $0.path.hasPrefix("/media/") || $0.path.hasPrefix("/hls/") }
        #expect(media.count > 2)
        #expect(media.allSatisfy { $0.headers["referer"] == "https://player.example/embed/1" })
        #expect(media.allSatisfy { $0.headers["origin"] == "https://player.example" })
        #expect(media.allSatisfy { $0.headers["user-agent"] == "Reader/3" })
        let versions = candidates.flatMap(\.versions)
        #expect(!versions.isEmpty)
        #expect(versions.allSatisfy { $0.referrer?.absoluteString == "https://player.example/embed/1" && $0.origin == "https://player.example" && $0.userAgent == "Reader/3" })
    }
}

private struct RulesReader: SiteReader {
    var video: SiteVideo
    var name: String { "Rules" }
    func recognises(_ page: URL) -> Bool { page.path.hasPrefix("/post/") }
    func post(in page: URL) -> String? { page.lastPathComponent }
    func read(_ page: SitePage) async throws -> [SiteVideo] { [video] }
}
