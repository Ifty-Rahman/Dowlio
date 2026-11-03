import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FeedTests {
    private func serveVideo(_ id: String, on site: Site, seconds: Int = 3) {
        let body = (0..<seconds).map { "#EXTINF:1.0,\n\($0).ts" }.joined(separator: "\n")
        site.serve(text: "#EXTM3U\n#EXT-X-TARGETDURATION:1\n\(body)\n#EXT-X-ENDLIST\n", at: "/amplify_video/\(id)/pl/360.m3u8")
    }

    private func player(_ group: Int, _ label: String, id: String, on site: Site, playing: Bool = false, visible: Double = 0) -> ScannedPlayer {
        ScannedPlayer(group: group, label: label, poster: site.url("/amplify_video_thumb/\(id)/img/p.jpg"), isPlaying: playing, visibility: visible)
    }

    private func watched(_ id: String, on site: Site) -> WatchedRequest {
        WatchedRequest(url: site.url("/amplify_video/\(id)/pl/360.m3u8"), kind: .manifest)
    }

    @Test func eachVideoInAFeedIsLabelledFromItsPostAndMatchedToItsStreamByID() async throws {
        let site = try await Site()
        site.serve(html: "<title>Home / X</title>", at: "/home")
        serveVideo("1111111111", on: site, seconds: 3)
        serveVideo("2222222222", on: site, seconds: 3)

        let found = try await site.analyze("/home") {
            $0.players = [
                player(1, "Ada: first post", id: "1111111111", on: site),
                player(2, "Grace: second post", id: "2222222222", on: site),
            ]
            $0.watched = [watched("2222222222", on: site), watched("1111111111", on: site)]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Ada: first post", "Grace: second post"])
        #expect(candidates.map(\.thumbnail) == [site.url("/amplify_video_thumb/1111111111/img/p.jpg"), site.url("/amplify_video_thumb/2222222222/img/p.jpg")])
        let first = candidates.first?.versions.first?.source.url
        #expect(first?.path.contains("1111111111") == true)
    }

    @Test func theVideoPlayingOrMostOnScreenComesFirstMarkedOnScreen() async throws {
        let site = try await Site()
        site.serve(html: "<title>Home</title>", at: "/home")
        for id in ["1111111111", "2222222222", "3333333333"] { serveVideo(id, on: site) }

        let found = try await site.analyze("/home") {
            $0.players = [
                player(1, "One", id: "1111111111", on: site, visible: 0.2),
                player(2, "Two", id: "2222222222", on: site, visible: 0.9),
                player(3, "Three", id: "3333333333", on: site, playing: true, visible: 0.1),
            ]
            $0.watched = ["1111111111", "2222222222", "3333333333"].map { watched($0, on: site) }
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Three", "Two", "One"])
        #expect(candidates.map(\.isOnScreen) == [true, false, false])
    }

    @Test func streamsThatMatchNoVideoOnTheFeedComeLastAsOtherVideos() async throws {
        let site = try await Site()
        site.serve(html: "<title>Home</title>", at: "/home")
        serveVideo("1111111111", on: site)
        serveVideo("2222222222", on: site)
        serveVideo("9999999999", on: site, seconds: 7)

        let found = try await site.analyze("/home") {
            $0.players = [player(1, "One", id: "1111111111", on: site), player(2, "Two", id: "2222222222", on: site)]
            $0.watched = ["9999999999", "1111111111", "2222222222"].map { watched($0, on: site) }
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.isOther) == [false, false, true])
        #expect(candidates.last?.duration == 7)
    }

    @Test func aPageWithOneVideoTakesItsUnmatchedStreamAsThatVideo() async throws {
        let site = try await Site()
        site.serve(html: "<title>Watch</title>", at: "/watch")
        serveVideo("5555555555", on: site)

        let found = try await site.analyze("/watch") {
            $0.players = [ScannedPlayer(group: 1, label: "Cooking pasta at home", visibility: 1)]
            $0.watched = [watched("5555555555", on: site)]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Cooking pasta at home"])
        #expect(candidates.map(\.isOther) == [false])
        #expect(candidates.map(\.isOnScreen) == [false])
    }

    @Test func hiddenEmptyPlayersDontMakeAPageAFeed() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>Watch</title>
            <meta property="video:duration" content="3">
            <meta property="og:video" content="/videos/1_240P_1000K_5555555555.mp4?hash=page">
            """, at: "/watch")
        serveVideo("5555555555", on: site)
        for token in ["page", "browser"] { site.serve(video: 500, at: "/videos/1_240P_1000K_5555555555.mp4?hash=\(token)") }

        let found = try await site.analyze("/watch") {
            $0.players = (1...4).map { ScannedPlayer(group: $0, label: "Related \($0)") }
                + [ScannedPlayer(group: 5, label: "Cooking pasta at home", duration: 3, visibility: 1)]
            $0.scan = [ScannedMedia(url: site.url("/videos/1_240P_1000K_5555555555.mp4?hash=browser"), kind: .video)]
            $0.watched = [watched("5555555555", on: site)]
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Cooking pasta at home"])
        #expect(candidates.map(\.isOther) == [false])
        let versions = try #require(candidates.first).versions
        #expect(versions.count == 2)
        #expect(versions.filter { $0.height == 240 }.count == 1)
    }

    @Test func onlyTheFirstFiveVideosAreProbedAndTheRestWhenOpened() async throws {
        let site = try await Site()
        site.serve(html: "<title>Home</title>", at: "/home")
        let ids = (1...7).map { String(repeating: String($0), count: 10) }
        for id in ids { serveVideo(id, on: site) }

        let found = try await site.analyze("/home") {
            $0.players = ids.enumerated().map { index, id in player(index + 1, "Post \(index + 1)", id: id, on: site) }
            $0.watched = ids.map { watched($0, on: site) }
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 7)
        #expect(candidates.prefix(5).allSatisfy { !$0.versions.isEmpty && $0.unprobed.isEmpty })
        #expect(candidates.suffix(2).allSatisfy { $0.versions.isEmpty && !$0.unprobed.isEmpty })
        #expect(site.server.requests.filter { $0.path.hasSuffix(".m3u8") }.count == 5)

        let opened = await site.analyzer.probe(candidates[6], on: SentPage(url: site.url("/home")))
        #expect(opened.label == "Post 7")
        #expect(opened.unprobed.isEmpty)
        #expect(opened.versions.first?.source.url.path.contains(ids[6]) == true)
    }

    @Test func aStreamPlayedInAnotherSitesFrameGoesToThatPlayerAndIsReadWithItsOrigin() async throws {
        let site = try await Site()
        site.serve(html: "<title>Movie - Tube</title>", at: "/watch")
        site.serve(video: 4000, at: "/ads/clip.mp4")
        let origin = "https://player.example"
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1868806,RESOLUTION=1280x720,CODECS=\"avc1.64001f,mp4a.40.2\"\n720p/index.txt\n"
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.0,\nseg_0.png\n#EXTINF:5.0,\nseg_1.png\n#EXT-X-ENDLIST\n"
        site.server.serve(TestServer.File(data: Data(master.utf8), headers: ["Content-Type": "text/plain; charset=utf-8"], requiredOrigin: origin), at: "/u/1/playlist.txt")
        site.server.serve(TestServer.File(data: Data(media.utf8), headers: ["Content-Type": "text/plain; charset=utf-8"], requiredOrigin: origin), at: "/u/1/720p/index.txt")

        let found = try await site.analyze("/watch") {
            $0.scan = [ScannedMedia(url: site.url("/ads/clip.mp4"), kind: .video, group: 1)]
            $0.players = [
                ScannedPlayer(group: 1, label: "Ad", duration: 5, visibility: 1, origin: URL(string: "https://ads.example")),
                ScannedPlayer(group: 2, label: "Movie", isPlaying: true, visibility: 1, origin: URL(string: origin)),
            ]
            $0.watched = [WatchedRequest(url: site.url("/u/1/playlist.txt"), kind: .manifest, contentType: "text/plain; charset=utf-8", referrer: URL(string: "\(origin)/"))]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Movie", "Ad"])
        #expect(candidates.first?.isOnScreen == true)
        #expect(candidates.first?.duration == 10)
        #expect(candidates.first?.versions.compactMap(\.height) == [720])
    }
}
