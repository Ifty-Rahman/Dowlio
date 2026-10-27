import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ThreadsReaderTests {
    private let post = "/@sampleauthor/post/Th12Re34Ad5"

    private func threads() async throws -> ReaderSite {
        try await ReaderSite { _ in ThreadsReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aPostsVideoIsReadFromTheEmbeddedDataOfThePage() async throws {
        let site = try await threads()
        try site.serve(fixture: "threads-post.html", at: post)

        let candidates = try await site.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "sampleauthor: A short clip from the harbour this morning")
        #expect(video.thumbnail == URL(string: "https://scontent.cdn.example/v/threads-thumb.jpg?oe=6AE4B7CE"))
        #expect(video.duration == 21.4)
        #expect(video.versions.map(\.height) == [1080])
        #expect(video.versions.map(\.codecs) == ["H.264 + AAC"])
    }

    @Test func onAProfileEveryLoadedPostsVideoIsListed() async throws {
        let site = try await threads()
        try site.serve(fixture: "threads-post.html", at: "/@sampleauthor")

        let candidates = try await site.candidates("/@sampleauthor")

        #expect(candidates.map(\.versions.first?.height) == [1080, 720])
    }

    @Test func aCarouselPostListsItsVideoThoughEachSlideHasItsOwnCode() async throws {
        let site = try await threads()
        site.site.serve(html: "<title>Threads</title>", at: post)
        let slides: [[String: Any]] = [
            ["pk": "61", "code": "Sl1de0ne000", "video_duration": 12.5, "original_width": 720, "original_height": 1280,
             "video_versions": [["type": 101, "url": "https://scontent.cdn.example/v/slide-one.mp4?oe=1"]]],
            ["pk": "62", "code": "Sl1deTw0000", "image_versions2": ["candidates": []]],
        ]
        let carousel: [String: Any] = [
            "pk": "60", "code": "Th12Re34Ad5", "caption": ["text": "Three angles of the new keyboard"],
            "user": ["username": "sampleauthor"], "carousel_media": slides,
        ]

        let candidates = try await site.candidates(post) { $0.embeddedJSON = [PageFixture.json(["post": carousel])] }

        #expect(candidates.map(\.label) == ["sampleauthor: Three angles of the new keyboard"])
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["slide-one.mp4"])
    }

    @Test func aPageWithoutPostDataIsLoggedAndFallsBack() async throws {
        let site = try await threads()
        site.site.serve(html: #"<title>Threads</title><video src="/media/clip.mp4"></video>"#, at: post)
        site.site.serve(video: 4_000, at: "/media/clip.mp4")

        let candidates = try await site.candidates(post)

        #expect(candidates.flatMap(\.versions).map(\.source) == [.file(site.url("/media/clip.mp4"))])
        #expect(site.log.failures == [ReaderFailure(reader: "Threads", site: site.host, reason: "found nothing")])
    }

    @Test func threadsRecognisesItsPermalinks() {
        let reader = ThreadsReader()
        #expect(reader.recognises(URL(string: "https://www.threads.net/@someone")!))
        #expect(reader.recognises(URL(string: "https://www.threads.com/@someone/post/DAbC123")!))
        #expect(reader.post(in: URL(string: "https://www.threads.com/@someone/post/DAbC123")!) == "DAbC123")
        #expect(reader.post(in: URL(string: "https://www.threads.com/t/DAbC123")!) == "DAbC123")
        #expect(reader.post(in: URL(string: "https://www.threads.com/@someone")!) == nil)
    }
}
