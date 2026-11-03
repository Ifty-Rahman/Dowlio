import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SocialReaderTests {
    private func server(_ site: ReaderSite) -> String {
        String(site.url("/").absoluteString.dropLast())
    }

    private func escaped(_ site: ReaderSite, slash: String) -> [String: String] {
        ["{{server}}": server(site), "{{escaped}}": server(site).replacingOccurrences(of: "/", with: slash)]
    }

    private func serveFiles(_ paths: [String], on site: ReaderSite, size: Int = 1_000_000) {
        for (index, path) in paths.enumerated() { site.site.serve(video: size + index, at: path) }
    }

    @Test func anImgurAlbumListsEachOfItsVideos() async throws {
        let site = try await ReaderSite { _ in ImgurReader(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "imgur-album.html", at: "/gallery/two-clips-Xy98Zw7", replacing: escaped(site, slash: "/"))
        serveFiles(["/Ab12Cd3.mp4", "/Ij78Kl9.mp4"], on: site)

        let candidates = try await site.candidates("/gallery/two-clips-Xy98Zw7")

        #expect(candidates.map(\.label) == ["Waves", "Two clips from the beach"])
        #expect(candidates.map { $0.versions.compactMap(\.height) } == [[720], [720]])
        #expect(candidates.map(\.duration) == [14, 9])
    }

    @Test func aMastodonPostOnAnyServerIsReadFromThatServersAPI() async throws {
        let site = try await ReaderSite { _ in MastodonReader() }
        try site.serve(fixture: "mastodon-status.json", at: "/api/v1/statuses/117524682227837661", replacing: escaped(site, slash: "/"))
        site.site.serve(html: #"<title>mas.to</title><script id="initial-state" type="application/json">{}</script>"#, at: "/@vvolhejn/117524682227837661")
        site.site.serve(video: 1_300_000, at: "/media_attachments/files/117/original/1e.mp4")

        let candidates = try await site.candidates("/@vvolhejn/117524682227837661")

        let video = try #require(candidates.first)
        #expect(video.label == "Václav Volhejn: Working on a new bytebeat editor")
        #expect(video.duration == 20.319)
        #expect(video.versions.compactMap(\.height) == [470])
        #expect(video.thumbnail?.lastPathComponent == "1e.png")
    }

    @Test func aTelegramPostIsReadFromItsEmbedPage() async throws {
        let site = try await ReaderSite { server in TelegramReader(hosts: ["127.0.0.1"], embeds: server.url(for: "/")) }
        try site.serve(fixture: "telegram-embed.html", at: "/telegram/441", replacing: escaped(site, slash: "/"))
        site.site.serve(video: 700_000, at: "/file/clip.mp4")

        let candidates = try await site.candidates("/telegram/441")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label.hasPrefix("Telegram News"))
        #expect(video.duration == 6)
        #expect(video.thumbnail?.lastPathComponent == "thumb.jpg")
        #expect(video.versions.map(\.totalBytes) == [700_000])
        let asked = site.site.server.requests.first { $0.path.hasPrefix("/telegram/441?") }
        #expect(asked?.path.contains("embed=1") == true)
    }

    @Test func aTenorPostListsOnlyItsOwnMP4Files() async throws {
        let site = try await ReaderSite { _ in AnimatedPostReader.tenor(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "tenor-view.html", at: "/view/good-morning-coffee-time-ghost-cup-jcroat-gif-3008999233979489984", replacing: escaped(site, slash: "\\u002F"))
        serveFiles(["/KcIc3GbFHsAAAAPo/good-morning-coffee-time.mp4", "/KcIc3GbFHsAAAAP1/good-morning-coffee-time.mp4", "/KcIc3GbFHsAAAAP1x/good-morning-coffee-time.mp4", "/RelatedOneAAAAPo/other.mp4"], on: site, size: 10_000)

        let candidates = try await site.candidates("/view/good-morning-coffee-time-ghost-cup-jcroat-gif-3008999233979489984")

        #expect(candidates.count == 1)
        let files = candidates.flatMap(\.versions).map { $0.source.url.pathComponents.dropFirst().first ?? "" }
        #expect(files == ["KcIc3GbFHsAAAAP1x", "KcIc3GbFHsAAAAPo", "KcIc3GbFHsAAAAP1"])
    }

    @Test func aGiphyPostListsOnlyItsOwnMP4Files() async throws {
        let site = try await ReaderSite { _ in AnimatedPostReader.giphy(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "giphy-gif.html", at: "/gifs/excited-applause-minions-MOWPkhRAUbR7i", replacing: escaped(site, slash: "/"))
        serveFiles(["/media/v1.abc/MOWPkhRAUbR7i/giphy.mp4", "/media/v1.abc/MOWPkhRAUbR7i/200.mp4", "/media/v1.abc/MOWPkhRAUbR7i/giphy-preview.mp4", "/media/v1.abc/OtherGif123/giphy.mp4"], on: site, size: 10_000)

        let candidates = try await site.candidates("/gifs/excited-applause-minions-MOWPkhRAUbR7i")

        #expect(candidates.count == 1)
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["giphy-preview.mp4", "200.mp4", "giphy.mp4"])
        #expect(candidates.first?.versions.last?.totalBytes == 61_671)
    }

    @Test func aNineGagPostListsItsMP4Files() async throws {
        let site = try await ReaderSite { _ in AnimatedPostReader.nineGag(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "ninegag-gag.html", at: "/gag/aB5oqEY", replacing: escaped(site, slash: "\\\\/"))
        serveFiles(["/photo/aB5oqEY_460sv.mp4", "/photo/aB5oqEY_460svh265.mp4", "/photo/aB5oqEY_460svav1.mp4", "/photo/zZ9yYxX_460sv.mp4"], on: site)

        let candidates = try await site.candidates("/gag/aB5oqEY")

        #expect(candidates.map(\.label) == ["Cat sees the vacuum"])
        #expect(Set(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent)) == ["aB5oqEY_460sv.mp4", "aB5oqEY_460svh265.mp4", "aB5oqEY_460svav1.mp4"])
    }

    @Test func aVKVideoIsReadFromItsPlayerParameters() async throws {
        let site = try await ReaderSite { server in VKReader(hosts: ["127.0.0.1"], embeds: server.url(for: "/video_ext.php")) }
        try site.serve(fixture: "vk-video-ext.html", at: "/video_ext.php", replacing: escaped(site, slash: "\\/"))
        site.site.serve(html: "<title>VK</title>", at: "/video-22822305_456239017")
        serveFiles(["/video/240.mp4", "/video/360.mp4", "/video/720.mp4"], on: site)

        let candidates = try await site.candidates("/video-22822305_456239017")

        let video = try #require(candidates.first)
        #expect(video.label == "Nature Channel: Aurora over the lake")
        #expect(video.duration == 95)
        #expect(Set(video.versions.compactMap(\.height)) == [240, 360, 720])
        let asked = site.site.server.requests.first { $0.path.hasPrefix("/video_ext.php") }
        #expect(asked?.path.contains("oid=-22822305") == true)
    }

    @Test func anOKVideoIsReadFromItsPlayerOptions() async throws {
        let site = try await ReaderSite { server in OKReader(hosts: ["127.0.0.1"], embeds: server.url(for: "/videoembed/")) }
        try site.serve(fixture: "ok-video.html", at: "/video/16638874618387", replacing: escaped(site, slash: "/"))
        serveFiles(["/ok/mobile.mp4", "/ok/lowest.mp4", "/ok/low.mp4", "/ok/sd.mp4", "/ok/hd.mp4", "/ok/full.mp4"], on: site)

        let candidates = try await site.candidates("/video/16638874618387")

        let video = try #require(candidates.first)
        #expect(video.label == "Новый мир. Кыргызстан")
        #expect(video.duration == 2274)
        #expect(Set(video.versions.compactMap(\.height)) == [144, 240, 360, 480, 720, 1080])
    }
}
