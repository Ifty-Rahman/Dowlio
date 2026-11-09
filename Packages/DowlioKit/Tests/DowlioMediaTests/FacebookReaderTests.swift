import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FacebookReaderTests {
    private func facebook() async throws -> ReaderSite {
        try await ReaderSite { _ in FacebookReader(hosts: ["127.0.0.1"]) }
    }

    private func reel() throws -> [String: Any] {
        try PageFixture.embedded("media", in: "facebook-reel")
    }

    private func video(id: String, seconds: Double, file: String) throws -> [String: Any] {
        var media = try reel()
        media["id"] = id
        media["length_in_second"] = seconds
        media["videoDeliveryResponseFragment"] = ["videoDeliveryResponseResult": [
            "id": id, "progressive_urls": [["progressive_url": file, "metadata": ["quality": "HD"]]], "dash_manifests": [],
        ]]
        return media
    }

    private func story(_ text: String, by author: String, showing media: [String: Any]) -> [String: Any] {
        ["message": ["text": text], "actors": [["name": author]], "attachments": [["media": media]]]
    }

    @Test func aReelIsReadFromTheEmbeddedDataOfThePage() async throws {
        let site = try await facebook()
        site.site.serve(html: try PageFixture.html("facebook-reel"), at: "/reel/3000000000000001/")

        let candidates = try await site.candidates("/reel/3000000000000001/")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.thumbnail == URL(string: "https://video.cdn.example/v/thumb.jpg?oe=6AE4B7CE"))
        #expect(video.duration == 135.185)
        let files = video.versions.filter { if case .file = $0.source { true } else { false } }
        #expect(files.map(\.source.url.lastPathComponent) == ["progressive-sd.mp4", "progressive-hd.mp4"])
        #expect(Set(files.compactMap(\.codecs)) == ["H.264 + AAC"])
        let av1 = video.versions.filter { $0.codecs?.hasPrefix("AV1") ?? false }
        #expect(av1.compactMap(\.height) == [360, 480, 540, 640, 720, 1080])
        #expect(video.versions.contains { $0.isAudio && $0.codecs == "AAC" })
    }

    @Test func aReelAPlainRequestGetsIsReadFromItsLegacyDeliveryFields() async throws {
        let site = try await facebook()
        site.site.serve(html: try PageFixture.html("facebook-reel-legacy"), at: "/reel/3000000000000001/")

        let candidates = try await site.candidates("/reel/3000000000000001/")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.duration == 135.185)
        #expect(video.thumbnail == URL(string: "https://video.cdn.example/v/thumb.jpg?oe=6AE4B7CE"))
        let files = video.versions.filter { if case .file = $0.source { true } else { false } }
        #expect(files.map(\.source.url.lastPathComponent) == ["legacy-sd.mp4", "legacy-hd.mp4"])
        let av1 = video.versions.filter { $0.codecs?.hasPrefix("AV1") ?? false }
        #expect(av1.compactMap(\.height) == [360, 480, 540, 640, 720, 1080])
        #expect(video.versions.contains { $0.isAudio })
    }

    @Test func aProgressiveFileTakesItsResolutionFromItsEncodingTag() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/reel/42/")
        let tag = Data(#"{"vencode_tag":"xpv_progressive.FACEBOOK..C3.720.dash_h264-basic-gen2_720p"}"#.utf8).base64EncodedString()
        let media = try video(id: "42", seconds: 10, file: "https://video.cdn.example/v/hd.mp4?efg=\(tag)&oe=1")

        let candidates = try await site.candidates("/reel/42/") { $0.embeddedJSON = [PageFixture.json(media)] }

        #expect(candidates.first?.versions.map(\.height) == [720])
    }

    @Test func aPermalinkListsOnlyThatVideo() async throws {
        let site = try await facebook()
        site.site.serve(html: try PageFixture.html("facebook-reel"), at: "/reel/3000000000000001/")
        let suggested = try video(id: "3000000000000002", seconds: 30, file: "https://video.cdn.example/v/suggested.mp4")

        let candidates = try await site.candidates("/reel/3000000000000001/") { $0.embeddedJSON = [PageFixture.json(suggested)] }

        #expect(candidates.map(\.duration) == [135.185])
    }

    @Test func aFeedsVideosAreLabelledWithTheirPostersAndPostTextAndTheOneOnScreenComesFirst() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/")
        let feed = [
            story("A long walk along the coast at sunset with the dog", by: "First Author", showing: try video(id: "11", seconds: 40, file: "https://video.cdn.example/v/one.mp4")),
            story("Cooking dinner", by: "Second Author", showing: try video(id: "22", seconds: 90, file: "https://video.cdn.example/v/two.mp4")),
        ]

        let candidates = try await site.candidates("/") {
            $0.embeddedJSON = [PageFixture.json(["data": ["feed": feed]])]
            $0.players = [ScannedPlayer(group: 1, duration: 40), ScannedPlayer(group: 2, duration: 90, isPlaying: true, visibility: 1)]
        }

        #expect(candidates.map(\.versions.first?.source.url.lastPathComponent) == ["two.mp4", "one.mp4"])
        #expect(candidates.map(\.isOnScreen) == [true, false])
        #expect(candidates.map(\.label) == ["Second Author - Cooking dinner", "First Author - A long walk along the coast"])
    }

    @Test func aVideoWithoutPostTextTakesTheLabelOfThePlayerThatLastsAsLong() async throws {
        let site = try await facebook()
        site.site.serve(html: try PageFixture.html("facebook-reel"), at: "/reel/3000000000000001/")

        let candidates = try await site.candidates("/reel/3000000000000001/") {
            $0.players = [ScannedPlayer(group: 1, label: "Sample Page: A reel about bread", duration: 135.2, isPlaying: true, visibility: 1)]
        }

        #expect(candidates.map(\.label) == ["Sample Page: A reel about bread"])
    }

    @Test func aFeedVideoKeepsItsPostTextOverTheTextAroundItsPlayer() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/")
        let feed = [story("Cooking dinner for the whole family tonight", by: "Second Author", showing: try video(id: "22", seconds: 90, file: "https://video.cdn.example/v/two.mp4"))]

        let candidates = try await site.candidates("/") {
            $0.embeddedJSON = [PageFixture.json(["data": ["feed": feed]])]
            $0.players = [ScannedPlayer(group: 1, label: "Second Author · Follow Original audio Cooking dinner", duration: 90, isPlaying: true, visibility: 1)]
        }

        #expect(candidates.map(\.label) == ["Second Author - Cooking dinner for the whole family"])
    }

    @Test func aVideoTakesItsPostersNameAndPostTextFromAPostKeptInAnotherPartOfThePage() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/reel/44/")
        var playable = try video(id: "44", seconds: 15, file: "https://video.cdn.example/v/reel.mp4")
        playable["owner"] = nil
        let post = story("Youri Tielemans putting on a show dominating the midfield vs Villa", by: "Manunitedborn", showing: ["id": "44", "__typename": "Video"])

        let candidates = try await site.candidates("/reel/44/") {
            $0.embeddedJSON = [PageFixture.json(["data": post]), PageFixture.json(playable)]
        }

        #expect(candidates.map(\.label) == ["Manunitedborn - Youri Tielemans putting on a show"])
    }

    @Test func aWatchVideoTakesItsPostTextFromItsDescription() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/watch/")
        var media = try video(id: "33", seconds: 60, file: "https://video.cdn.example/v/watch.mp4")
        media["savable_description"] = ["text": "Morning run along the river with the whole crew"]

        let candidates = try await site.candidates("/watch/?v=33") { $0.embeddedJSON = [PageFixture.json(media)] }

        #expect(candidates.map(\.label) == ["Morning run along the river with"])
    }

    @Test func aReelIsNamedAfterItsPosterAndTheFirstWordsOfItsPostKeptBesideTheVideo() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/reel/3000000000000001/")
        let media = try video(id: "3000000000000001", seconds: 30, file: "https://video.cdn.example/v/reel.mp4")
        let reel: [String: Any] = ["video": ["creation_story": [
            "comet_sections": [
                "actor_photo": ["story": ["actors": [["name": "Sample Creator"]]]],
                "message": ["story": ["message": ["text": "Morning run along the river with the whole crew today"]]],
            ],
            "attachments": [["media": media]],
        ]]]

        let candidates = try await site.candidates("/reel/3000000000000001/") { $0.embeddedJSON = [PageFixture.json(reel)] }

        #expect(candidates.map(\.label) == ["Sample Creator - Morning run along the river with"])
    }

    @Test func aReelWithoutACaptionIsNamedAfterItsPoster() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/reel/3000000000000001/")
        let media = try video(id: "3000000000000001", seconds: 30, file: "https://video.cdn.example/v/reel.mp4")
        let reel: [String: Any] = ["video": ["creation_story": [
            "short_form_video_context": ["video_owner": ["name": "Sample Creator"]],
            "attachments": [["media": media]],
        ]]]

        let candidates = try await site.candidates("/reel/3000000000000001/") { $0.embeddedJSON = [PageFixture.json(reel)] }

        #expect(candidates.map(\.label) == ["Sample Creator"])
    }

    @Test func aPostThatStartsWithItsPostersNameIsNotNamedTwice() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/somepage/posts/1/")
        let feed = [story("Sample Page is live from the river tonight", by: "Sample Page", showing: try video(id: "55", seconds: 40, file: "https://video.cdn.example/v/live.mp4"))]

        let candidates = try await site.candidates("/somepage/posts/1/") { $0.embeddedJSON = [PageFixture.json(["data": feed])] }

        #expect(candidates.map(\.label) == ["Sample Page is live from the"])
    }

    @Test func aShareLinkThatRedirectsReadsTheReelItLandsOn() async throws {
        let site = try await facebook()
        site.site.server.redirect("/share/r/abc/", to: site.url("/reel/66/").absoluteString)
        site.site.serve(html: try reelPage(showing: ["66", "77"]), at: "/reel/66/")

        let candidates = try await site.candidates("/share/r/abc/")

        #expect(candidates.map { $0.versions.first?.source.url.lastPathComponent } == ["66.mp4"])
    }

    @Test func aShareLinkThatRefreshesToItsReelReadsThatReel() async throws {
        let site = try await facebook()
        let reel = site.url("/reel/66/").absoluteString
        site.site.serve(html: "<head><meta http-equiv=\"refresh\" content=\"0; url=\(reel)\"></head>", at: "/share/r/abc/")
        site.site.serve(html: try reelPage(showing: ["66", "77"]), at: "/reel/66/")

        let candidates = try await site.candidates("/share/r/abc/")

        #expect(candidates.map { $0.versions.first?.source.url.lastPathComponent } == ["66.mp4"])
    }

    @Test func aLinkThatRedirectsToAPageThatIsNoPostKeepsTheLinkItWasSent() async throws {
        let site = try await facebook()
        site.site.server.redirect("/reel/66/", to: site.url("/login/").absoluteString)
        site.site.serve(html: try reelPage(showing: ["77", "66"]), at: "/login/")

        let candidates = try await site.candidates("/reel/66/")

        #expect(candidates.map { $0.versions.first?.source.url.lastPathComponent } == ["66.mp4"])
    }

    private func reelPage(showing ids: [String]) throws -> String {
        let feed = try ids.map { id in
            story("Reel number \(id)", by: "Sample Creator", showing: try video(id: id, seconds: 20, file: "https://video.cdn.example/v/\(id).mp4"))
        }
        return "<title>Facebook</title><script type=\"application/json\" data-sjs>\(PageFixture.json(["data": feed]))</script>"
    }

    @Test func aLiveVideoIsShownAsLive() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/watch/")
        var live = try video(id: "55", seconds: 0, file: "https://video.cdn.example/v/live.mp4")
        live["is_live_streaming"] = true

        let found = try await site.site.analyze("/watch/?v=55") { $0.embeddedJSON = [PageFixture.json(live)] }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.live])
    }

    @Test func aVideoWithALicenceIsShownAsProtected() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/reel/66/")
        var locked = try video(id: "66", seconds: 20, file: "https://video.cdn.example/v/locked.mp4")
        locked["drm_info"] = #"{"video_license_uri_map": {"widevine": "https://license.example/wv"}}"#

        let found = try await site.site.analyze("/reel/66/") { $0.embeddedJSON = [PageFixture.json(locked)] }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.protected])
    }

    @Test func aPostPageListsThePostsVideoWhenItsAddressNamesThePostNotTheVideo() async throws {
        let site = try await facebook()
        site.site.serve(html: "<title>Facebook</title>", at: "/somepage/posts/pfbid02AbCd/")
        let feed = [
            story("The post itself", by: "Sample Page", showing: try video(id: "11", seconds: 40, file: "https://video.cdn.example/v/own.mp4")),
            story("Suggested for you", by: "Other Page", showing: try video(id: "22", seconds: 90, file: "https://video.cdn.example/v/other.mp4")),
        ]

        let candidates = try await site.candidates("/somepage/posts/pfbid02AbCd/") { $0.embeddedJSON = [PageFixture.json(["data": feed])] }

        #expect(candidates.map(\.label) == ["Sample Page - The post itself"])
    }

    @Test func aPageWithoutVideoDataIsLoggedAndFallsBack() async throws {
        let site = try await facebook()
        site.site.serve(html: #"<title>Facebook</title><video src="/media/clip.mp4"></video>"#, at: "/reel/77/")
        site.site.serve(video: 4_000, at: "/media/clip.mp4")

        let candidates = try await site.candidates("/reel/77/")

        #expect(candidates.flatMap(\.versions).map(\.source) == [.file(site.url("/media/clip.mp4"))])
        #expect(site.log.failures == [ReaderFailure(reader: "Facebook", site: site.host, reason: "found nothing")])
    }

    @Test func facebookRecognisesItsPermalinks() {
        let reader = FacebookReader()
        #expect(reader.recognises(URL(string: "https://www.facebook.com/")!))
        #expect(reader.post(in: URL(string: "https://www.facebook.com/reel/1093975340009986")!) == "1093975340009986")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/watch/?v=123")!) == "123")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/somepage/videos/a-title/456/")!) == "456")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/somepage/posts/789")!) == "789")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/somepage/posts/pfbid02AbCd")!) == "pfbid02AbCd")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/share/v/1AbCdE/")!) == "1AbCdE")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/groups/somegroup/permalink/321/")!) == "321")
        #expect(reader.post(in: URL(string: "https://fb.watch/aBcD1/")!) == "aBcD1")
        #expect(reader.post(in: URL(string: "https://www.facebook.com/")!) == nil)
    }
}
