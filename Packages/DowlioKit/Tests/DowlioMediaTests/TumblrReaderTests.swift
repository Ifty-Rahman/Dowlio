import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TumblrReaderTests {
    private func tumblr() async throws -> ReaderSite {
        try await ReaderSite { _ in TumblrReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aPostsVideoIsReadFromThePagesState() async throws {
        let site = try await tumblr()
        try site.serve(fixture: "tumblr-posts.html", at: "/sampleblog/800000000000000001")

        let candidates = try await site.candidates("/sampleblog/800000000000000001")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "sampleblog: Our dog learned to open the fridge and")
        #expect(video.thumbnail == URL(string: "https://64.media.tumblr.example/SampleVideo01/s540x810/poster.jpg"))
        #expect(video.versions.map(\.source.url.lastPathComponent) == ["tumblr_SampleVideo01.mp4"])
        #expect(video.versions.map(\.height) == [576])
    }

    @Test func onADashboardEveryTumblrVideoIsListedWithARebloggedOneLabelledByItsOriginalPost() async throws {
        let site = try await tumblr()
        try site.serve(fixture: "tumblr-posts.html", at: "/dashboard")

        let candidates = try await site.candidates("/dashboard")

        #expect(candidates.map(\.label) == ["sampleblog: Our dog learned to open the fridge and", "originalblog: Original clip from the beach"])
        #expect(candidates.map(\.versions.first?.height) == [576, 720])
    }

    @Test func aRebloggedPostsPermalinkListsTheVideoItReblogged() async throws {
        let site = try await tumblr()
        try site.serve(fixture: "tumblr-posts.html", at: "/post/800000000000000002")

        let candidates = try await site.candidates("/post/800000000000000002")

        #expect(candidates.map(\.label) == ["originalblog: Original clip from the beach"])
    }

    @Test func aPermalinkToTheOriginalPostListsTheVideoFromAReblogOfIt() async throws {
        let site = try await tumblr()
        try site.serve(fixture: "tumblr-posts.html", at: "/originalblog/700000000000000001")

        let candidates = try await site.candidates("/originalblog/700000000000000001")

        #expect(candidates.map(\.label) == ["originalblog: Original clip from the beach"])
    }

    @Test func aPostThatOnlyEmbedsAnotherSitesVideoIsLoggedAsFindingNothing() async throws {
        let site = try await tumblr()
        try site.serve(fixture: "tumblr-posts.html", at: "/thirdblog/800000000000000003")

        let found = try await site.site.analyze("/thirdblog/800000000000000003")

        #expect(found == .found([]))
        #expect(site.log.failures == [ReaderFailure(reader: "Tumblr", site: site.host, reason: "found nothing")])
    }

    @Test func tumblrRecognisesItsPermalinks() {
        let reader = TumblrReader()
        #expect(reader.recognises(URL(string: "https://someblog.tumblr.com/")!))
        #expect(reader.post(in: URL(string: "https://www.tumblr.com/viralfrog/818114486493921280")!) == "818114486493921280")
        #expect(reader.post(in: URL(string: "https://www.tumblr.com/viralfrog/818114486493921280/a-slug")!) == "818114486493921280")
        #expect(reader.post(in: URL(string: "https://viralfrog.tumblr.com/post/818114486493921280")!) == "818114486493921280")
        #expect(reader.post(in: URL(string: "https://www.tumblr.com/blog/view/viralfrog/818114486493921280")!) == "818114486493921280")
        #expect(reader.post(in: URL(string: "https://www.tumblr.com/dashboard")!) == nil)
        #expect(reader.post(in: URL(string: "https://www.tumblr.com/tagged/video")!) == nil)
    }
}
