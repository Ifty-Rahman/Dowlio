import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RedditReaderTests {
    private let post = "/r/sample/comments/1abcdef/sample_post_title_about_a_video/"

    private func reddit() async throws -> ReaderSite {
        try await ReaderSite { RedditReader(hosts: ["127.0.0.1"], videos: $0.url(for: "/v"), redgifs: $0.url(for: "/redgifs")) }
    }

    private func serveRedditVideo(at folder: String, on site: ReaderSite) throws {
        let master = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/hls-master-cmaf-subtitles", withExtension: "m3u8")), encoding: .utf8)
        site.site.serve(text: master, at: "\(folder)/HLSPlaylist.m3u8")
        for quality in ["220", "270", "360", "480", "720", "1080", "AUDIO_128", "AUDIO_64"] {
            site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "CMAF_\(quality)-"), at: "\(folder)/CMAF_\(quality).m3u8")
        }
    }

    @Test func aPostsVideoIsReadFromItsPlayerOnThePage() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-post-video.html", at: post, replacing: ["{{server}}": site.url("/v").absoluteString, "{{video}}": "sample9video"])
        try serveRedditVideo(at: "/v/sample9video", on: site)

        let candidates = try await site.candidates(post)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "sampleauthor: Sample post title about a video that someone")
        #expect(video.thumbnail == URL(string: "https://preview.redd.example/sample-poster.jpg?width=1080&format=pjpg&s=signature"))
        #expect(video.versions.compactMap(\.height) == [220, 270, 360, 480, 720, 1080])
    }

    @Test func aFeedsRedGifsAndRedditVideosAreReadThroughTheirPublicPlaylists() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-feed-redgifs.html", at: "/r/sample/", replacing: ["{{video}}": "sample8video"])
        try serveRedditVideo(at: "/v/sample8video", on: site)
        let clip = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/hls-media-single-file-absolute", withExtension: "m3u8")), encoding: .utf8)
        site.site.serve(text: clip, at: "/redgifs/samplefirstclip/hd.m3u8")
        site.site.serve(text: clip.replacingOccurrences(of: "-mobile", with: ""), at: "/redgifs/samplefirstclip/sd.m3u8")

        let candidates = try await site.candidates("/r/sample/")

        #expect(candidates.map(\.label) == ["firstauthor: First clip", "thirdauthor: Second clip"])
        #expect(candidates.first?.versions.map(\.source.url.lastPathComponent).sorted() == ["SampleClipName-mobile.m4s", "SampleClipName.m4s"])
        #expect(candidates.first?.versions.allSatisfy { $0.totalBytes != nil && !$0.isEstimatedSize } == true)
        #expect(candidates.last?.versions.compactMap(\.height).max() == 1080)
    }

    @Test func aPermalinkListsOnlyThatPostsVideo() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-post-video.html", at: post, replacing: ["{{server}}": site.url("/v").absoluteString, "{{video}}": "sample9video"])
        try serveRedditVideo(at: "/v/sample9video", on: site)
        try serveRedditVideo(at: "/v/relatedvideo1", on: site)

        let candidates = try await site.candidates(post)

        #expect(candidates.map(\.label) == ["sampleauthor: Sample post title about a video that someone"])
    }

    @Test func aShareLinkListsThePagesOwnPost() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-post-video.html", at: "/r/sample/s/AbCdEf123", replacing: ["{{server}}": site.url("/v").absoluteString, "{{video}}": "sample9video"])
        try serveRedditVideo(at: "/v/sample9video", on: site)
        try serveRedditVideo(at: "/v/relatedvideo1", on: site)

        let candidates = try await site.candidates("/r/sample/s/AbCdEf123")

        #expect(candidates.map(\.label) == ["sampleauthor: Sample post title about a video that someone"])
    }

    @Test func aPageWithoutPostsIsLoggedAndFallsBack() async throws {
        let site = try await reddit()
        site.site.serve(html: #"<title>Reddit</title><video src="/media/clip.mp4"></video>"#, at: post)
        site.site.serve(video: 4_000, at: "/media/clip.mp4")

        let candidates = try await site.candidates(post)

        #expect(candidates.flatMap(\.versions).map(\.source) == [.file(site.url("/media/clip.mp4"))])
        #expect(site.log.failures == [ReaderFailure(reader: "Reddit", site: site.host, reason: "found nothing")])
    }

    @Test func redditRecognisesItsPermalinks() {
        let reader = RedditReader()
        #expect(reader.recognises(URL(string: "https://www.reddit.com/r/videos/")!))
        #expect(reader.post(in: URL(string: "https://www.reddit.com/r/videos/comments/1xfmpoa/a_title/")!) == "1xfmpoa")
        #expect(reader.post(in: URL(string: "https://redd.it/1xfmpoa")!) == "1xfmpoa")
        #expect(reader.post(in: URL(string: "https://www.reddit.com/r/videos/s/AbCdEf123")!) == "AbCdEf123")
        #expect(reader.post(in: URL(string: "https://www.reddit.com/r/videos/")!) == nil)
    }
}
