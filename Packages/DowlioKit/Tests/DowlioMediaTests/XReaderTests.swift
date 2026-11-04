import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct XReaderTests {
    private let post = "/sampleauthor/status/1000000000000000001"

    private func xSite() async throws -> ReaderSite {
        try await ReaderSite { XReader(hosts: ["127.0.0.1"], api: $0.url(for: "/tweet-result")) }
    }

    @Test func aPostsVideoIsListedBeforeThePageHasLoadedIt() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>Sample Author on X</title><div id=react-root></div>", at: post)
        try x.serve(fixture: "x-tweet-result.json", at: "/tweet-result")

        let candidates = try await x.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Author: Sample post text about the match that ends")
        #expect(video.thumbnail == URL(string: "https://pbs.twimg.example/amplify_video_thumb/2000000000000000002/img/thumb.jpg"))
        #expect(video.duration == 66.888)
        #expect(video.versions.compactMap(\.height) == [320, 480, 720, 1080])
        #expect(Set(video.versions.compactMap(\.codecs)) == ["H.264 + AAC"])
        #expect(video.versions.allSatisfy { $0.isEstimatedSize })
        #expect(video.versions.last?.totalBytes == 86_686_848)
        #expect(x.site.server.requests.contains { $0.path.hasPrefix("/tweet-result?id=1000000000000000001&token=") })
    }

    @Test func aPermalinkListsOnlyThatPostsVideo() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>Sample Author on X</title>", at: post)
        try x.serve(fixture: "x-tweet-result.json", at: "/tweet-result")
        x.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "reply"), at: "/amplify_video/3000000000000000003/pl/reply.m3u8")

        let candidates = try await x.candidates(post) {
            $0.watched = [WatchedRequest(url: x.url("/amplify_video/3000000000000000003/pl/reply.m3u8"), kind: .manifest)]
        }

        #expect(candidates.count == 1)
        #expect(candidates.first?.label == "Sample Author: Sample post text about the match that ends")
    }

    @Test func aPostOpenedFromSearchShowsOnlyItsOwnVideoWhileLooking() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>Sample Author on X</title>", at: post)
        try x.serve(fixture: "x-tweet-result.json", at: "/tweet-result")
        let searched = (1...6).map { "/amplify_video/300000000000000000\($0)/vid/avc1/0/0/720x1280/search.mp4" }
        for path in searched { x.site.serve(video: 4096, at: path) }
        var page = SentPage(url: x.url(post), throughDowlioConnect: true)
        page.watched = searched.map { WatchedRequest(url: x.url($0), kind: .file) }

        var updates: [PageAnalysis] = []
        for await update in x.site.analyzer.analyze(page) { updates.append(update) }

        #expect(updates.count == 1)
        guard case .found(let candidates)? = updates.last else { Issue.record("not found: \(updates)"); return }
        #expect(candidates.map(\.label) == ["Sample Author: Sample post text about the match that ends"])
        #expect(!x.site.server.requests.contains { $0.path.hasSuffix("search.mp4") })
    }

    @Test func aPostServedOnlyAsAPlaylistIsReadThroughThePlaylist() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>X</title>", at: post)
        x.site.serve(text: #"""
            {"text": "Looping clip", "user": {"name": "Sample Author"}, "mediaDetails": [{"type": "animated_gif",
             "video_info": {"variants": [{"content_type": "application/x-mpegURL", "url": "\#(x.url("/pl/clip.m3u8").absoluteString)"}]}}]}
            """#, type: "application/json", at: "/tweet-result")
        x.site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=720x1280
            720/clip.m3u8
            """, at: "/pl/clip.m3u8")
        x.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "seg"), at: "/pl/720/clip.m3u8")

        let candidates = try await x.candidates(post)

        #expect(candidates.map(\.label) == ["Sample Author: Looping clip"])
        #expect(candidates.first?.versions.compactMap(\.height) == [720])
    }

    @Test func whenTheReaderFailsItIsLoggedAndThePagesOwnVideoIsStillFound() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>Sample Author on X</title>", at: post)
        x.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "seg"), at: "/pl/own.m3u8")

        let candidates = try await x.candidates(post) {
            $0.watched = [WatchedRequest(url: x.url("/pl/own.m3u8"), kind: .manifest)]
        }

        #expect(candidates.count == 1)
        #expect(x.log.failures.map(\.reader) == ["X"])
        #expect(x.log.failures.map(\.site) == [x.host])
    }

    @Test func aPostWithoutVideoIsLoggedAsFindingNothing() async throws {
        let x = try await xSite()
        x.site.serve(html: "<title>X</title>", at: post)
        x.site.serve(text: #"{"text": "Just words", "user": {"name": "Sample Author"}, "mediaDetails": []}"#, type: "application/json", at: "/tweet-result")

        let found = try await x.site.analyze(post)

        #expect(found == .found([]))
        #expect(x.log.failures == [ReaderFailure(reader: "X", site: x.host, reason: "found nothing")])
    }

    @Test func xRecognisesItsPermalinks() {
        let reader = XReader()
        #expect(!reader.recognises(URL(string: "https://x.com/home")!))
        #expect(reader.recognises(URL(string: "https://mobile.twitter.com/someone/status/123")!))
        #expect(!reader.recognises(URL(string: "https://example.com/someone/status/123")!))
        #expect(reader.post(in: URL(string: "https://x.com/someone/status/2114410791650709507/video/1")!) == "2114410791650709507")
        #expect(reader.post(in: URL(string: "https://x.com/i/web/status/42")!) == "42")
        #expect(reader.post(in: URL(string: "https://x.com/home")!) == nil)
        #expect(reader.post(in: URL(string: "https://x.com/someone")!) == nil)
    }
}
