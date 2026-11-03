import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LinkedInReaderTests {
    private let post = "/posts/sample-company_fashion-career-lore-activity-7500000000000000001-XMki"

    private func linkedIn() async throws -> ReaderSite {
        try await ReaderSite { _ in LinkedInReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aPostsVideoIsReadFromItsPlayerOnThePage() async throws {
        let site = try await linkedIn()
        try site.serve(fixture: "linkedin-post.html", at: post)

        let candidates = try await site.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Company: Fashion, but make it career lore. Sample Pe…")
        #expect(video.thumbnail?.host() == "media.licdn.example")
        #expect(video.versions.compactMap(\.height) == [640, 720])
        #expect(video.versions.allSatisfy { $0.source.url.host() == "dms.licdn.example" })
    }

    @Test func aCompanyPageListsEveryPostsVideo() async throws {
        let site = try await linkedIn()
        try site.serve(fixture: "linkedin-post.html", at: "/company/sample/")

        let candidates = try await site.candidates("/company/sample/")

        #expect(candidates.count == 2)
        #expect(candidates.last?.label == "Other Company: A different post further down the page")
    }

    @Test func aPermalinkNamingThePostsOwnIDListsThatPost() async throws {
        let site = try await linkedIn()
        try site.serve(fixture: "linkedin-post.html", at: "/feed/update/urn:li:ugcPost:7400000000000000001/")

        let candidates = try await site.candidates("/feed/update/urn:li:ugcPost:7400000000000000001/")

        #expect(candidates.map(\.label) == ["Sample Company: Fashion, but make it career lore. Sample Pe…"])
    }

    @Test func aPostWithoutVideoIsLoggedAsFindingNothing() async throws {
        let site = try await linkedIn()
        try site.serve(fixture: "linkedin-post.html", at: "/feed/update/urn:li:activity:7500000000000000009/")

        let found = try await site.site.analyze("/feed/update/urn:li:activity:7500000000000000009/")

        #expect(found == .found([]))
        #expect(site.log.failures == [ReaderFailure(reader: "LinkedIn", site: site.host, reason: "found nothing")])
    }

    @Test func linkedInRecognisesItsPermalinks() {
        let reader = LinkedInReader()
        #expect(reader.recognises(URL(string: "https://www.linkedin.com/feed/")!))
        #expect(reader.post(in: URL(string: "https://www.linkedin.com/posts/linkedin_fashion-activity-7518673300387082240-XMki")!) == "7518673300387082240")
        #expect(reader.post(in: URL(string: "https://www.linkedin.com/feed/update/urn:li:activity:7518673300387082240/")!) == "7518673300387082240")
        #expect(reader.post(in: URL(string: "https://www.linkedin.com/company/linkedin")!) == nil)
    }
}
