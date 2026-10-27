import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BlueskyReaderTests {
    private let post = "/profile/sampleauthor.bsky.social/post/3sampleposta2"
    private let folder = "/watch/did%3Aplc%3Asampleauthor000000000000/bafkreisamplevideocid"

    private func bluesky() async throws -> ReaderSite {
        try await ReaderSite { BlueskyReader(hosts: ["127.0.0.1"], api: $0.url(for: "/xrpc")) }
    }

    private func serveVideo(on site: ReaderSite) throws {
        let master = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/hls-master-query-session", withExtension: "m3u8")), encoding: .utf8)
        site.site.serve(text: master, at: "\(folder)/playlist.m3u8")
        for quality in ["360p", "720p"] {
            site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "video"), at: "\(folder)/\(quality)/video.m3u8")
        }
    }

    @Test func aPostsVideoIsReadThroughBlueskysPublicAPI() async throws {
        let site = try await bluesky()
        site.site.serve(html: "<title>Bluesky</title>", at: post)
        try site.serve(fixture: "bluesky-post-thread.json", at: "/xrpc/app.bsky.feed.getPostThread", replacing: ["{{server}}": site.url("").absoluteString])
        try serveVideo(on: site)

        let candidates = try await site.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Author: Version two is out today with a new")
        #expect(video.thumbnail?.lastPathComponent == "thumbnail.jpg")
        #expect(video.duration == 12)
        #expect(video.versions.compactMap(\.height) == [360, 720])
        let asked = try #require(site.site.server.requests.first { $0.path.hasPrefix("/xrpc/") })
        #expect(asked.path.contains("uri=at://sampleauthor.bsky.social/app.bsky.feed.post/3sampleposta2"))
    }

    @Test func aPostWithoutVideoIsLoggedAndThePagesOwnResultsStand() async throws {
        let site = try await bluesky()
        site.site.serve(html: "<title>Bluesky</title>", at: post)
        site.site.serve(text: #"{"thread": {"post": {"record": {"text": "Words only"}, "author": {"handle": "sampleauthor.bsky.social"}}}}"#, type: "application/json", at: "/xrpc/app.bsky.feed.getPostThread")

        let found = try await site.site.analyze(post)

        #expect(found == .found([]))
        #expect(site.log.failures == [ReaderFailure(reader: "Bluesky", site: site.host, reason: "found nothing")])
    }

    @Test func whenBlueskysAPIFailsItIsLoggedAndThePagesOwnResultsStand() async throws {
        let site = try await bluesky()
        site.site.serve(html: "<title>Bluesky</title>", at: post)

        let found = try await site.site.analyze(post)

        #expect(found == .found([]))
        #expect(site.log.failures.map(\.reader) == ["Bluesky"])
        #expect(site.log.failures.first?.reason != "found nothing")
    }

    @Test func blueskyRecognisesItsPermalinks() {
        let reader = BlueskyReader()
        #expect(reader.recognises(URL(string: "https://bsky.app/profile/someone.bsky.social/post/3myi2ihquwk26")!))
        #expect(!reader.recognises(URL(string: "https://bsky.app/profile/someone.bsky.social")!))
        #expect(!reader.recognises(URL(string: "https://bsky.app/post/3myi2ihquwk26")!))
        #expect(reader.post(in: URL(string: "https://bsky.app/profile/did:plc:abc/post/3myi2ihquwk26")!) == "3myi2ihquwk26")
    }
}
