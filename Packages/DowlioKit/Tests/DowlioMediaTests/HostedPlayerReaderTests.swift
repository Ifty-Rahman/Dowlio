import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HostedPlayerReaderTests {
    private func placeholders(_ site: ReaderSite) -> [String: String] {
        ["{{server}}": String(site.url("/").absoluteString.dropLast()), "{{host}}": "\(site.host):\(site.url("/").port!)"]
    }

    private func serveStream(at path: String, on site: ReaderSite) {
        let folder = (path as NSString).deletingLastPathComponent
        site.site.serve(text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\nv.m3u8\n", at: path)
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "s"), at: "\(folder)/v.m3u8")
        for index in 0..<2 { site.site.serve(video: 100_000, type: "video/mp2t", at: "\(folder)/s\(index).ts") }
    }

    private func vimeo() async throws -> ReaderSite {
        try await ReaderSite { server in VimeoReader(hosts: ["127.0.0.1"], player: server.url(for: "/")) }
    }

    @Test func aVimeoVideoListsItsFilesAndItsStreamsFromThePlayerConfig() async throws {
        let site = try await vimeo()
        try site.serve(fixture: "vimeo-config.json", at: "/video/76979871/config", replacing: placeholders(site))
        site.site.serve(html: "<title>Vimeo</title>", at: "/76979871")
        site.site.serve(video: 9_000_000, at: "/progressive/76979871-720.mp4")
        site.site.serve(video: 3_000_000, at: "/progressive/76979871-360.mp4")
        serveStream(at: "/exp=1~acl=x~hmac=y/76979871/playlist.m3u8", on: site)

        let candidates = try await site.candidates("/76979871")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "The New Vimeo Player (You Know, For Videos)")
        #expect(video.duration == 62)
        #expect(video.thumbnail == site.url("/video/452001751-d"))
        #expect(Set(video.versions.compactMap(\.height)) == [360, 720, 1080])
    }

    @Test func aVimeoEmbedOnAnotherPageIsReadWithThatPageAsReferrer() async throws {
        let site = try await vimeo()
        try site.serve(fixture: "vimeo-config.json", at: "/video/76979871/config", replacing: placeholders(site))
        site.site.serve(html: "", at: "/video/76979871")
        site.site.serve(video: 9_000_000, at: "/progressive/76979871-720.mp4")
        site.site.serve(video: 3_000_000, at: "/progressive/76979871-360.mp4")
        site.site.serve(html: #"<title>Our launch</title><iframe src="/video/76979871?h=abc123" width="640" height="360"></iframe>"#, at: "/blog/launch")

        let candidates = try await site.candidates("/blog/launch")

        #expect(candidates.map(\.label) == ["The New Vimeo Player (You Know, For Videos)"])
        let config = site.site.server.requests.first { $0.path.hasPrefix("/video/76979871/config") }
        #expect(config?.path.contains("h=abc123") == true)
        #expect(config?.headers["referer"] == site.url("/blog/launch").absoluteString)
    }

    @Test func aVimeoPlayerAddedInScriptIsFoundWithoutAFrame() async throws {
        let site = try await vimeo()
        try site.serve(fixture: "vimeo-config.json", at: "/video/76979871/config", replacing: placeholders(site))
        site.site.serve(html: "", at: "/video/76979871")
        site.site.serve(video: 9_000_000, at: "/progressive/76979871-720.mp4")
        site.site.serve(video: 3_000_000, at: "/progressive/76979871-360.mp4")
        let player = site.url("/video/76979871").absoluteString.replacingOccurrences(of: "/", with: "\\/")
        site.site.serve(html: #"<title>Launch</title><div id="v"></div><script>new Vimeo.Player("v", {"url":"\#(player)"});</script>"#, at: "/blog/launch")

        let candidates = try await site.candidates("/blog/launch")

        #expect(candidates.map(\.label) == ["The New Vimeo Player (You Know, For Videos)"])
    }

    @Test func aVimeoAddressWithoutAVideoIsNotAVideo() {
        let reader = VimeoReader()
        #expect(reader.post(in: URL(string: "https://vimeo.com/showcase/1234567/video/76979871")!) == "76979871")
        #expect(reader.post(in: URL(string: "https://vimeo.com/76979871/abc123def0")!) == "76979871")
        #expect(reader.post(in: URL(string: "https://vimeo.com/user12345678/videos")!) == nil)
        #expect(reader.post(in: URL(string: "https://vimeo.com/ondemand/film/123456")!) == nil)
    }

    @Test func aPasswordProtectedVimeoVideoNeedsItsPassword() async throws {
        let site = try await vimeo()
        try site.serve(fixture: "vimeo-config-password.json", at: "/video/11111111/config")
        site.site.serve(html: "<title>Private</title>", at: "/11111111")

        let candidates = try await site.candidates("/11111111")

        #expect(candidates.map(\.restriction) == [.needsPassword])
    }

    @Test func aDailymotionVideoListsItsStreamWithItsLargestPoster() async throws {
        let site = try await ReaderSite { server in DailymotionReader(hosts: ["127.0.0.1"], api: server.url(for: "/player/metadata/video/")) }
        try site.serve(fixture: "dailymotion-metadata.json", at: "/player/metadata/video/x8j3e7e", replacing: placeholders(site))
        site.site.serve(html: "<title>Dailymotion</title>", at: "/video/x8j3e7e")
        serveStream(at: "/cdn/manifest/video/x8j3e7e.m3u8", on: site)

        let candidates = try await site.candidates("/video/x8j3e7e")

        let video = try #require(candidates.first)
        #expect(video.label == "Wie sexistisch ist die KI-Porträt-App Lensa?")
        #expect(video.thumbnail == site.url("/thumb/x1080.jpg"))
        #expect(video.versions.compactMap(\.height) == [1080])
    }

    @Test func aStreamableVideoListsItsFiles() async throws {
        let site = try await ReaderSite { server in StreamableReader(hosts: ["127.0.0.1"], api: server.url(for: "/videos/")) }
        try site.serve(fixture: "streamable-video.json", at: "/videos/moo", replacing: placeholders(site))
        site.site.serve(html: "<title>Streamable</title>", at: "/moo")
        site.site.serve(video: 4_000_000, at: "/video/mp4/f6441ae0.mp4")
        site.site.serve(video: 2_000_000, at: "/video/mp4-mobile/f6441ae0.mp4")

        let candidates = try await site.candidates("/moo")

        let video = try #require(candidates.first)
        #expect(video.label == "\"Please don't eat me!\"")
        #expect(video.thumbnail?.path == "/image/f6441ae0.jpg")
        #expect(Set(video.versions.compactMap(\.height)) == [360, 480])
    }

    @Test func aLoomShareListsItsTranscodedFile() async throws {
        let site = try await ReaderSite { server in LoomReader(hosts: ["127.0.0.1"], api: server.url(for: "/api/campaigns/sessions/")) }
        try site.serve(fixture: "loom-transcoded-url.json", at: "/api/campaigns/sessions/09b1aa507cb846138847bf8e98b56a71/transcoded-url", replacing: placeholders(site))
        site.site.serve(html: #"<title>Unstuck your team with Loom</title>"#, at: "/share/09b1aa507cb846138847bf8e98b56a71")
        site.site.serve(video: 5_000_000, at: "/sessions/transcoded/09b1aa507cb846138847bf8e98b56a71.mp4")

        let candidates = try await site.candidates("/share/09b1aa507cb846138847bf8e98b56a71")

        #expect(candidates.map(\.label) == ["Unstuck your team with Loom"])
        #expect(candidates.flatMap(\.versions).map(\.totalBytes) == [5_000_000])
        let asked = site.site.server.requests.first { $0.path.hasSuffix("/transcoded-url") }
        #expect(asked?.method == "POST")
    }
}
