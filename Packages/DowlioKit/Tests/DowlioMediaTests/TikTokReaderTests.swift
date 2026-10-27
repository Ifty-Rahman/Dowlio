import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TikTokReaderTests {
    private let post = "/@sampleauthor/video/7100000000000000001"

    private func tiktok() async throws -> ReaderSite {
        try await ReaderSite { _ in TikTokReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aVideoIsReadFromThePagesData() async throws {
        let site = try await tiktok()
        try site.serve(fixture: "tiktok-video.html", at: post)

        let candidates = try await site.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Author: Teaching the cat to high five took three")
        #expect(video.thumbnail == URL(string: "https://p16-sign.tiktokcdn.example/obj/cover.jpeg?x-expires=1790000000&x-signature=signature"))
        #expect(video.duration == 15)
        #expect(video.versions.map(\.height) == [576, 576, 1080])
        #expect(video.versions.map(\.codecs) == ["H.264 + AAC", "H.264 + AAC", "HEVC + AAC"])
        #expect(video.versions.map(\.totalBytes) == [1_500_000, 940_000, 2_448_000])
    }

    @Test func aPermalinkToAnotherVideoListsNothingFromThisOne() async throws {
        let site = try await tiktok()
        try site.serve(fixture: "tiktok-video.html", at: "/@sampleauthor/video/7199999999999999999")

        let found = try await site.site.analyze("/@sampleauthor/video/7199999999999999999")

        #expect(found == .found([]))
        #expect(site.log.failures.map(\.reason) == ["found nothing"])
    }

    @Test func aShortLinkListsThePagesVideo() async throws {
        let site = try await tiktok()
        try site.serve(fixture: "tiktok-video.html", at: "/t/ZTAbCd123/")

        let candidates = try await site.candidates("/t/ZTAbCd123/")

        #expect(candidates.map(\.duration) == [15])
    }

    @Test func theVideoDowlioConnectSentIsReadWhenThePageItselfHasNone() async throws {
        let site = try await tiktok()
        site.site.serve(html: "<title>TikTok</title>", at: post)
        let item: [String: Any] = ["itemStruct": [
            "id": "7100000000000000001", "desc": "Short", "author": ["uniqueId": "sampleauthor"],
            "video": ["duration": 9, "width": 720, "height": 1280, "codecType": "h264", "playAddr": "https://v16-webapp-prime.tiktok.example/video/tos/play.mp4"],
        ]]

        let candidates = try await site.candidates(post) { $0.embeddedJSON = [PageFixture.json(item)] }

        #expect(candidates.map(\.label) == ["sampleauthor: Short"])
        #expect(candidates.first?.versions.map(\.height) == [720])
    }

    @Test func tiktokRecognisesItsPermalinks() {
        let reader = TikTokReader()
        #expect(reader.recognises(URL(string: "https://www.tiktok.com/foryou")!))
        #expect(reader.post(in: URL(string: "https://www.tiktok.com/@someone/video/7106594312292453675")!) == "7106594312292453675")
        #expect(reader.post(in: URL(string: "https://m.tiktok.com/v/7106594312292453675.html")!) == "7106594312292453675")
        #expect(reader.post(in: URL(string: "https://vm.tiktok.com/ZMAbCdEf/")!) == "ZMAbCdEf")
        #expect(reader.post(in: URL(string: "https://www.tiktok.com/@someone")!) == nil)
    }
}
