import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BusinessPlayerReaderTests {
    private func placeholders(_ site: ReaderSite) -> [String: String] {
        ["{{server}}": String(site.url("/").absoluteString.dropLast())]
    }

    private func serveStream(at path: String, on site: ReaderSite) {
        let folder = (path as NSString).deletingLastPathComponent
        site.site.serve(text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\nv.m3u8\n", at: path)
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "s"), at: "\(folder)/v.m3u8")
        for index in 0..<2 { site.site.serve(video: 100_000, type: "video/mp2t", at: "\(folder)/s\(index).ts") }
    }

    @Test func aWistiaEmbedListsTheMediasFiles() async throws {
        let site = try await ReaderSite { server in WistiaReader(hosts: ["127.0.0.1"], medias: server.url(for: "/embed/medias/")) }
        try site.serve(fixture: "wistia-media.json", at: "/embed/medias/7sc5jnc9e0.json", replacing: placeholders(site))
        site.site.serve(html: #"<title>Pricing</title><div class="wistia_embed wistia_async_7sc5jnc9e0 videoFoam=true"></div>"#, at: "/pricing")
        for name in ["701bb9d05e06", "5d1519a30373", "eecf6ac7f9f2", "5539b7dc204f", "8dc3556f075f", "a8944a20f5a0"] {
            site.site.serve(video: 1_000_000, at: "/deliveries/\(name).bin")
        }

        let candidates = try await site.candidates("/pricing")

        let video = try #require(candidates.first)
        #expect(video.label == "Homepage MAP loop")
        #expect(video.thumbnail?.lastPathComponent == "2093591ffaa2.jpg")
        #expect(Set(video.versions.compactMap(\.height)) == [224, 360, 540, 720, 1080, 2160])
        #expect(video.versions.first { $0.height == 1080 }?.totalBytes == 2_406_816)
    }

    @Test func aBrightcovePlayerOnAPageIsReadThroughItsPolicyKey() async throws {
        let site = try await ReaderSite { server in
            BrightcoveReader(hosts: ["127.0.0.1"], players: server.url(for: "/"), playback: server.url(for: "/playback/v1/accounts/"))
        }
        try site.serve(fixture: "brightcove-player.js", at: "/1752604059001/default_default/index.min.js")
        try site.serve(fixture: "brightcove-playback.json", at: "/playback/v1/accounts/1752604059001/videos/5802784116001", replacing: placeholders(site))
        site.site.serve(html: #"<title>Ocean news</title><video-js data-account="1752604059001" data-player="default" data-embed="default" data-video-id="5802784116001" controls></video-js>"#, at: "/news/turtles")
        serveStream(at: "/hls/5802784116001/master.m3u8", on: site)
        site.site.serve(video: 9_452_212, at: "/mp4/5802784116001-1280.mp4")
        site.site.serve(video: 3_301_250, at: "/mp4/5802784116001-640.mp4")

        let candidates = try await site.candidates("/news/turtles")

        let video = try #require(candidates.first)
        #expect(video.label == "Sea turtles")
        #expect(video.duration == 31.488)
        #expect(Set(video.versions.compactMap(\.height)) == [360, 720, 1080])
        let playback = site.site.server.requests.first { $0.path.hasPrefix("/playback/") }
        #expect(playback?.headers["accept"] == "application/json;pk=BCpkTESTpolicyKey00000000000000000000")
    }

    @Test func aBrightcoveVideoWhoseSourcesAreAllProtectedIsProtected() async throws {
        let site = try await ReaderSite { server in
            BrightcoveReader(hosts: ["127.0.0.1"], players: server.url(for: "/"), playback: server.url(for: "/playback/v1/accounts/"))
        }
        try site.serve(fixture: "brightcove-player.js", at: "/1752604059001/default_default/index.min.js")
        try site.serve(fixture: "brightcove-playback-protected.json", at: "/playback/v1/accounts/1752604059001/videos/6000000000001")
        site.site.serve(html: "<title>Player</title>", at: "/1752604059001/default_default/index.html")

        let candidates = try await site.candidates("/1752604059001/default_default/index.html?videoId=6000000000001")

        #expect(candidates.map(\.restriction) == [.protected])
    }

    @Test func aKalturaPlayerIsReadThroughItsPartnersPlayManifest() async throws {
        let site = try await ReaderSite { server in KalturaReader(hosts: ["127.0.0.1"], api: server.url(for: "/")) }
        try site.serve(fixture: "kaltura-embed.html", at: "/company/update", replacing: placeholders(site))
        serveStream(at: "/p/811441/sp/81144100/playManifest/entryId/1_2t0wlwjk/format/applehttp/protocol/https/a.m3u8", on: site)
        site.site.serve(video: 4_000_000, at: "/p/811441/sp/81144100/playManifest/entryId/1_2t0wlwjk/format/url/protocol/https/a.mp4")

        let candidates = try await site.candidates("/company/update")

        let video = try #require(candidates.first)
        #expect(video.label == "Company update - Kaltura customer")
        #expect(video.thumbnail == site.url("/p/811441/thumbnail/entry_id/1_2t0wlwjk/width/640"))
        #expect(video.versions.contains { $0.height == 1080 })
        #expect(video.versions.contains { $0.totalBytes == 4_000_000 })
    }

    @Test func aVidyardEmbedListsEachChaptersFilesAndItsAutoStream() async throws {
        let site = try await ReaderSite { server in VidyardReader(hosts: ["127.0.0.1"], player: server.url(for: "/")) }
        try site.serve(fixture: "vidyard-player.json", at: "/player/JvvRU6eiRYmDDHUm8zVimc.json", replacing: placeholders(site))
        site.site.serve(html: #"<title>Demo</title><img class="vidyard-player-embed" src="/thumb.jpg" data-uuid="JvvRU6eiRYmDDHUm8zVimc" data-v="4" data-type="inline">"#, at: "/demo")
        for profile in ["1080p", "720p", "480p", "360p"] { site.site.serve(video: 2_000_000, at: "/videos/\(profile).mp4") }
        serveStream(at: "/media/hls/auto.m3u8", on: site)

        let candidates = try await site.candidates("/demo")

        let video = try #require(candidates.first)
        #expect(video.label == "Transform Buyer Relationships With Video")
        #expect(video.duration == 110)
        #expect(Set(video.versions.compactMap(\.height)) == [360, 480, 720, 1080])
    }
}
