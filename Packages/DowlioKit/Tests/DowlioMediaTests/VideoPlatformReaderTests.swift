import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct VideoPlatformReaderTests {
    private func placeholders(_ site: ReaderSite) -> [String: String] {
        ["{{server}}": String(site.url("/").absoluteString.dropLast())]
    }

    private func serveStream(at path: String, on site: ReaderSite) {
        let folder = (path as NSString).deletingLastPathComponent
        site.site.serve(text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\nv.m3u8\n", at: path)
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "s"), at: "\(folder)/v.m3u8")
        for index in 0..<2 { site.site.serve(video: 100_000, type: "video/mp2t", at: "\(folder)/s\(index).ts") }
    }

    private func twitch() async throws -> ReaderSite {
        try await ReaderSite { TwitchReader(hosts: ["127.0.0.1"], api: $0.url(for: "/gql"), usher: $0.url(for: "/usher/")) }
    }

    @Test func aTwitchClipListsItsMP4FilesSignedWithItsAccessToken() async throws {
        let site = try await twitch()
        try site.serve(fixture: "twitch-clip.json", at: "/gql", replacing: placeholders(site))
        site.site.serve(html: "<title>Twitch</title>", at: "/samplechannel/clip/SampleSlugOne")
        site.site.serve(video: 4_000_000, at: "/clips/SampleSlugOne-720.mp4")
        site.site.serve(video: 1_000_000, at: "/clips/SampleSlugOne-360.mp4")

        let candidates = try await site.candidates("/samplechannel/clip/SampleSlugOne")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample clutch round")
        #expect(video.duration == 28)
        #expect(Set(video.versions.compactMap(\.height)) == [360, 720])
        let signed = try #require(video.versions.first?.source.url)
        let items = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "sig" }?.value == "abc123sig")
        #expect(items.first { $0.name == "token" }?.value?.contains("SampleSlugOne") == true)
        let asked = site.site.server.requests.first { $0.path == "/gql" }
        #expect(asked?.method == "POST")
        #expect(asked?.headers["client-id"]?.isEmpty == false)
    }

    @Test func aPastBroadcastListsItsPlaylistFromTheAccessToken() async throws {
        let site = try await twitch()
        try site.serve(fixture: "twitch-broadcast.json", at: "/gql", replacing: placeholders(site))
        site.site.serve(html: "<title>Twitch</title>", at: "/videos/123456789")
        serveStream(at: "/usher/vod/123456789.m3u8", on: site)

        let candidates = try await site.candidates("/videos/123456789")

        let video = try #require(candidates.first)
        #expect(video.label == "Sample past broadcast")
        #expect(video.duration == 3600)
        #expect(video.thumbnail == site.url("/thumb/vod-1280x720.jpg"))
        #expect(video.versions.compactMap(\.height) == [1080])
        let playlist = site.site.server.requests.first { $0.path.hasPrefix("/usher/vod/123456789.m3u8") }
        #expect(playlist?.path.contains("sig=vodsig") == true)
    }

    @Test func aLiveChannelShowsLiveStream() async throws {
        let site = try await twitch()
        try site.serve(fixture: "twitch-channel-live.json", at: "/gql")
        site.site.serve(html: "<title>SampleChannel - Twitch</title>", at: "/samplechannel")

        let candidates = try await site.candidates("/samplechannel")

        #expect(candidates.map(\.restriction) == [.live])
        #expect(candidates.map(\.label) == ["Live right now"])
    }

    @Test func anOfflineChannelFindsNothing() async throws {
        let site = try await twitch()
        try site.serve(fixture: "twitch-channel-offline.json", at: "/gql")
        site.site.serve(html: "<title>SampleChannel - Twitch</title>", at: "/samplechannel")

        let found = try await site.site.analyze("/samplechannel")

        if case .found(let candidates) = found.withoutExtractedAudio { #expect(candidates.isEmpty) }
        #expect(site.log.failures.contains { $0.reader == "Twitch" })
    }

    @Test func twitchAddressesAreRecognisedByKind() {
        let reader = TwitchReader()
        #expect(reader.post(in: URL(string: "https://www.twitch.tv/somebody/clip/FamousSlug-abc")!) == "FamousSlug-abc")
        #expect(reader.post(in: URL(string: "https://clips.twitch.tv/FamousSlug-abc")!) == "FamousSlug-abc")
        #expect(reader.post(in: URL(string: "https://www.twitch.tv/videos/123456789")!) == "123456789")
        #expect(reader.post(in: URL(string: "https://www.twitch.tv/somebody/videos/123456789")!) == "123456789")
        #expect(reader.recognises(URL(string: "https://www.twitch.tv/somebody")!))
        #expect(reader.post(in: URL(string: "https://www.twitch.tv/somebody")!) == nil)
        #expect(!reader.recognises(URL(string: "https://www.twitch.tv/directory")!))
        #expect(!reader.recognises(URL(string: "https://www.twitch.tv/")!))
    }

    private func kick() async throws -> ReaderSite {
        try await ReaderSite { KickReader(hosts: ["127.0.0.1"], api: $0.url(for: "/api/")) }
    }

    @Test func aKickClipListsItsFile() async throws {
        let site = try await kick()
        try site.serve(fixture: "kick-clip.json", at: "/api/v2/clips/clip_01SAMPLE", replacing: placeholders(site))
        site.site.serve(html: "<title>Kick</title>", at: "/samplechannel/clips/clip_01SAMPLE")
        site.site.serve(video: 3_000_000, at: "/clips/clip_01SAMPLE.mp4")

        let candidates = try await site.candidates("/samplechannel/clips/clip_01SAMPLE")

        let video = try #require(candidates.first)
        #expect(video.label == "Sample kick clip")
        #expect(video.duration == 30)
        #expect(video.versions.compactMap(\.totalBytes) == [3_000_000])
    }

    @Test func aKickPastBroadcastListsItsPlaylist() async throws {
        let site = try await kick()
        let id = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
        try site.serve(fixture: "kick-video.json", at: "/api/v1/video/\(id)", replacing: placeholders(site))
        site.site.serve(html: "<title>Kick</title>", at: "/video/\(id)")
        serveStream(at: "/vod/master.m3u8", on: site)

        let candidates = try await site.candidates("/video/\(id)")

        let video = try #require(candidates.first)
        #expect(video.label == "Sample past stream")
        #expect(video.duration == 7200)
        #expect(video.versions.compactMap(\.height) == [1080])
    }

    @Test func aLiveKickChannelShowsLiveStream() async throws {
        let site = try await kick()
        try site.serve(fixture: "kick-channel-live.json", at: "/api/v2/channels/samplechannel")
        site.site.serve(html: "<title>Kick</title>", at: "/samplechannel")

        let candidates = try await site.candidates("/samplechannel")

        #expect(candidates.map(\.restriction) == [.live])
    }

    @Test func anOfflineKickChannelFindsNothing() async throws {
        let site = try await kick()
        try site.serve(fixture: "kick-channel-offline.json", at: "/api/v2/channels/samplechannel")
        site.site.serve(html: "<title>Kick</title>", at: "/samplechannel")

        let found = try await site.site.analyze("/samplechannel")

        if case .found(let candidates) = found.withoutExtractedAudio { #expect(candidates.isEmpty) }
        #expect(site.log.failures.contains { $0.reader == "Kick" })
    }

    @Test func kickAddressesAreRecognisedByKind() {
        let reader = KickReader()
        #expect(reader.post(in: URL(string: "https://kick.com/somebody/clips/clip_01ABC")!) == "clip_01ABC")
        #expect(reader.post(in: URL(string: "https://kick.com/somebody/videos/6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f")!) == "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f")
        #expect(reader.post(in: URL(string: "https://kick.com/somebody?clip=clip_01ABC")!) == "clip_01ABC")
        #expect(reader.post(in: URL(string: "https://kick.com/video/6F1C2D3E-4A5B-4C6D-8E7F-0A1B2C3D4E5F")!) == "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f")
        #expect(reader.recognises(URL(string: "https://kick.com/somebody")!))
        #expect(!reader.recognises(URL(string: "https://kick.com/categories")!))
        #expect(!reader.recognises(URL(string: "https://kick.com/")!))
    }

    private func rumble() async throws -> ReaderSite {
        try await ReaderSite { RumbleReader(hosts: ["127.0.0.1"], api: $0.url(for: "/embedJS/u3/")) }
    }

    @Test func aRumbleEmbedListsItsFilesWithTheirSizes() async throws {
        let site = try await rumble()
        try site.serve(fixture: "rumble-embed.json", at: "/embedJS/u3/", replacing: placeholders(site))
        site.site.serve(html: "<title>Rumble</title>", at: "/embed/v5sample/")
        site.site.serve(video: 2_000_000, at: "/video/v-360.mp4")
        site.site.serve(video: 6_000_000, at: "/video/v-720.mp4")

        let candidates = try await site.candidates("/embed/v5sample/")

        let video = try #require(candidates.first)
        #expect(video.label == "Sample Rumble video")
        #expect(video.duration == 95)
        #expect(Set(video.versions.compactMap(\.height)) == [360, 720])
        let asked = site.site.server.requests.first { $0.path.hasPrefix("/embedJS/u3/") }
        #expect(asked?.path.contains("v=v5sample") == true)
    }

    @Test func aRumbleVideoPageIsReadThroughItsEmbed() async throws {
        let site = try await rumble()
        try site.serve(fixture: "rumble-embed.json", at: "/embedJS/u3/", replacing: placeholders(site))
        try site.serve(fixture: "rumble-page.html", at: "/v5sample-sample-rumble-video.html")
        site.site.serve(video: 2_000_000, at: "/video/v-360.mp4")
        site.site.serve(video: 6_000_000, at: "/video/v-720.mp4")

        let candidates = try await site.candidates("/v5sample-sample-rumble-video.html")

        #expect(candidates.map(\.label) == ["Sample Rumble video"])
        let asked = site.site.server.requests.first { $0.path.hasPrefix("/embedJS/u3/") }
        #expect(asked?.path.contains("v=v5sample") == true)
    }

    @Test func aLiveRumbleVideoShowsLiveStream() async throws {
        let site = try await rumble()
        try site.serve(fixture: "rumble-live.json", at: "/embedJS/u3/", replacing: placeholders(site))
        site.site.serve(html: "<title>Rumble</title>", at: "/embed/v5live/")

        let candidates = try await site.candidates("/embed/v5live/")

        #expect(candidates.map(\.restriction) == [.live])
    }

    @Test func rumbleEmbedsOnOtherPagesAreFound() {
        let reader = RumbleReader()
        #expect(reader.embeds(in: #"<iframe src="https://rumble.com/embed/v5sample/?pub=4"></iframe>"#) == [URL(string: "https://rumble.com/embed/v5sample/")!])
        #expect(reader.recognises(URL(string: "https://rumble.com/embed/v5sample/")!))
        #expect(reader.recognises(URL(string: "https://rumble.com/v5sample-a-title.html")!))
        #expect(!reader.recognises(URL(string: "https://rumble.com/c/SomeChannel")!))
    }
}
