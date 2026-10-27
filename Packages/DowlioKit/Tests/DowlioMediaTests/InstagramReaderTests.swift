import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct InstagramReaderTests {
    private func instagram() async throws -> ReaderSite {
        try await ReaderSite { _ in InstagramReader(hosts: ["127.0.0.1"]) }
    }

    private func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Pages/instagram-reel", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func reel() throws -> [String: Any] {
        let html = try fixture()
        let start = try #require(html.range(of: "data-sjs>")).upperBound
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let page = try JSONSerialization.jsonObject(with: Data(html[start..<end].utf8))
        return try #require(Self.first("xig_fetch_media", in: page) as? [String: Any])
    }

    private static func first(_ key: String, in value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let found = object[key] { return found }
            return object.values.lazy.compactMap { first(key, in: $0) }.first
        }
        return (value as? [Any])?.lazy.compactMap { first(key, in: $0) }.first
    }

    private func reel(code: String, caption: String, seconds: Double) throws -> [String: Any] {
        var other = try reel()
        other["code"] = code
        other["pk"] = code
        other["caption"] = ["text": caption]
        other["video_duration"] = seconds
        other["video_versions"] = [["width": 720, "height": 1280, "url": "https://scontent.cdn.example/v/\(code).mp4"]]
        other["video_dash_manifest"] = nil
        return other
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func aReelIsReadFromTheEmbeddedDataOfThePage() async throws {
        let site = try await instagram()
        site.site.serve(html: try fixture(), at: "/reel/Ab12Cd34Ef5/")

        let candidates = try await site.candidates("/reel/Ab12Cd34Ef5/")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Account: Sample caption for a reel")
        #expect(video.thumbnail == URL(string: "https://scontent.cdn.example/v/thumb.jpg?oe=6AE4B7CE"))
        #expect(video.duration == 45.952)
        let progressive = video.versions.filter { $0.source == .file(URL(string: "https://scontent.cdn.example/v/progressive.mp4?oe=6AE4B7CE&oh=signature")!) }
        #expect(progressive.map(\.height) == [720])
        #expect(progressive.map(\.codecs) == ["H.264 + AAC"])
        let vp9 = video.versions.filter { $0.codecs?.hasPrefix("VP9") ?? false }
        #expect(vp9.compactMap(\.height) == [240, 270, 360, 480, 540, 640, 720, 1080])
        #expect(video.versions.contains { $0.isAudio && $0.codecs == "AAC" })
    }

    @Test func theDataDowlioConnectSentIsReadWhenThePageItselfHasNone() async throws {
        let site = try await instagram()
        site.site.serve(html: "<title>Instagram</title>", at: "/reel/Ab12Cd34Ef5/")
        let reel = try reel()

        let candidates = try await site.candidates("/reel/Ab12Cd34Ef5/") { $0.embeddedJSON = [try! self.json(reel)] }

        #expect(candidates.map(\.label) == ["Sample Account: Sample caption for a reel"])
        #expect(candidates.first?.versions.count == 10)
    }

    @Test func theSizeOfAReelsFileIsAskedForWhenTheDataHasNone() async throws {
        let site = try await instagram()
        site.site.serve(html: "<title>Instagram</title>", at: "/reel/Aa11Bb22Cc3/")
        site.site.serve(video: 3_000, at: "/v/reel.mp4")
        var reel = try reel(code: "Aa11Bb22Cc3", caption: "Sized reel", seconds: 12)
        reel["video_versions"] = [["width": 720, "height": 1280, "url": site.url("/v/reel.mp4").absoluteString]]

        let candidates = try await site.candidates("/reel/Aa11Bb22Cc3/") { $0.embeddedJSON = [try! self.json(reel)] }

        #expect(candidates.first?.versions.map(\.totalBytes) == [3_000])
    }

    @Test func aCarouselsVideosTakeTheCaptionOfTheirPost() async throws {
        let site = try await instagram()
        site.site.serve(html: "<title>Instagram</title>", at: "/p/Ca12Ro34Us5/")
        let post: [String: Any] = [
            "code": "Ca12Ro34Us5", "pk": "77", "caption": ["text": "Two clips from the beach"], "user": ["username": "sampleaccount"],
            "carousel_media": [
                ["pk": "78", "video_versions": [["width": 720, "height": 1280, "url": "https://scontent.cdn.example/v/one.mp4"]]],
                ["pk": "79", "image_versions2": ["candidates": []]],
                ["pk": "80", "video_versions": [["width": 1080, "height": 1080, "url": "https://scontent.cdn.example/v/two.mp4"]]],
            ],
        ]

        let candidates = try await site.candidates("/p/Ca12Ro34Us5/") { $0.embeddedJSON = [try! self.json(post)] }

        #expect(candidates.map(\.label) == ["sampleaccount: Two clips from the beach", "sampleaccount: Two clips from the beach"])
        #expect(candidates.compactMap { $0.versions.first?.height } == [720, 1080])
    }

    @Test func aPermalinkListsOnlyThatReel() async throws {
        let site = try await instagram()
        site.site.serve(html: try fixture(), at: "/p/Ab12Cd34Ef5/")
        let other = try reel(code: "Zz99Yy88Xx7", caption: "Another reel", seconds: 12)

        let candidates = try await site.candidates("/p/Ab12Cd34Ef5/") { $0.embeddedJSON = [try! self.json(other)] }

        #expect(candidates.map(\.label) == ["Sample Account: Sample caption for a reel"])
    }

    @Test func onAFeedTheReelsTakeTheLabelsAndOrderOfThePlayersShowingThem() async throws {
        let site = try await instagram()
        site.site.serve(html: "<title>Instagram</title>", at: "/reels/")
        let first = try reel(code: "Aa11Bb22Cc3", caption: "First reel", seconds: 45.9)
        let second = try reel(code: "Dd44Ee55Ff6", caption: "Second reel", seconds: 27.8)

        let candidates = try await site.candidates("/reels/") {
            $0.embeddedJSON = [try! self.json(["items": [first, second]])]
            $0.players = [
                ScannedPlayer(group: 1, label: "sampleaccount • Follow First reel", duration: 45.93),
                ScannedPlayer(group: 2, label: "otheraccount • Follow Second reel", duration: 27.83, isPlaying: true, visibility: 1),
            ]
        }

        #expect(candidates.map(\.label) == ["otheraccount • Follow Second reel", "sampleaccount • Follow First reel"])
        #expect(candidates.map(\.isOnScreen) == [true, false])
        #expect(candidates.map { $0.versions.first?.source.url.lastPathComponent } == ["Dd44Ee55Ff6.mp4", "Aa11Bb22Cc3.mp4"])
    }

    @Test func aPageWithoutReelDataIsLoggedAndFallsBack() async throws {
        let site = try await instagram()
        site.site.serve(html: #"<title>Instagram</title><video src="/media/clip.mp4"></video>"#, at: "/p/Ab12Cd34Ef5/")
        site.site.serve(video: 4_000, at: "/media/clip.mp4")

        let candidates = try await site.candidates("/p/Ab12Cd34Ef5/")

        #expect(candidates.flatMap(\.versions).map(\.source) == [.file(site.url("/media/clip.mp4"))])
        #expect(site.log.failures == [ReaderFailure(reader: "Instagram", site: site.host, reason: "found nothing")])
    }

    @Test func instagramRecognisesItsPermalinks() {
        let reader = InstagramReader()
        #expect(reader.recognises(URL(string: "https://www.instagram.com/")!))
        #expect(reader.post(in: URL(string: "https://www.instagram.com/reels/De630xiCsVU/")!) == "De630xiCsVU")
        #expect(reader.post(in: URL(string: "https://www.instagram.com/someone/p/Ab_1-x/")!) == "Ab_1-x")
        #expect(reader.post(in: URL(string: "https://www.instagram.com/reels/")!) == nil)
        #expect(reader.post(in: URL(string: "https://www.instagram.com/someone/")!) == nil)
    }
}
