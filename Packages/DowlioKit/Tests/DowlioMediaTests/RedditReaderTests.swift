import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RedditReaderTests {
    private let post = "/r/sample/comments/1abcdef/sample_post_title_about_a_video/"

    private func reddit() async throws -> ReaderSite {
        try await ReaderSite { RedditReader(hosts: ["127.0.0.1"], videos: $0.url(for: "/v"), clips: $0.url(for: "/clips")) }
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

    @Test func aFeedsShortClipsAreReadThroughTheirApiAsMP4FilesAndRedditVideosThroughTheirPlaylists() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-feed-clips.html", at: "/r/sample/", replacing: ["{{video}}": "sample8video"])
        try serveRedditVideo(at: "/v/sample8video", on: site)
        try site.serve(fixture: "clip-token.json", at: "/clips/auth/temporary")
        try site.serve(fixture: "clip-gif.json", at: "/clips/gifs/samplefirstclip", replacing: ["{{media}}": site.url("/media").absoluteString])
        site.site.serve(video: 1_500_000, at: "/media/SampleFirstClip.mp4")
        site.site.serve(video: 600_000, at: "/media/SampleFirstClip-mobile.mp4")

        let candidates = try await site.candidates("/r/sample/")

        #expect(candidates.map(\.label) == ["firstauthor: First clip", "thirdauthor: Second clip"])
        #expect(candidates.first?.versions.map(\.source.url.lastPathComponent).sorted() == ["SampleFirstClip-mobile.mp4", "SampleFirstClip.mp4"])
        #expect(candidates.first?.versions.allSatisfy { $0.totalBytes != nil && !$0.isEstimatedSize } == true)
        #expect(candidates.last?.versions.compactMap(\.height).max() == 1080)
    }

    @Test func aHomeFeedVideoListsEveryResolutionOfItsPlaylistRatherThanTheOneFileItsPlayerPlays() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-home-feed.html", at: "/", replacing: ["{{video}}": "sample7video", "{{media}}": site.url("/media").absoluteString])
        try serveRedditVideo(at: "/v/sample7video", on: site)
        for height in [240, 360, 480, 720] {
            site.site.serve(video: 10_000 * height, at: "/media/feedvideo/pb/m2-res_\(height)p.mp4")
            site.site.serve(video: 10_000 * height, at: "/media/packaged/pb/m2-res_\(height)p.mp4")
        }

        let candidates = try await site.candidates("/")

        #expect(candidates.map(\.label) == ["feedauthor: A video on the home feed", "packagedauthor: A packaged video"])
        #expect(candidates.first?.versions.compactMap(\.height) == [220, 270, 360, 480, 720, 1080])
        #expect(candidates.last?.versions.compactMap(\.height).sorted() == [240, 360, 720])
    }

    @Test func aFeedVideoTheBrowserPlaysThatThePageNeverHeldListsEveryResolutionOfItsPlaylist() async throws {
        let site = try await reddit()
        site.site.serve(html: "<title>Reddit</title>", at: "/")
        try serveRedditVideo(at: "/v/sample6video", on: site)

        let candidates = try await site.candidates("/") {
            $0.scan = [ScannedMedia(url: URL(string: "https://packaged-media.redd.it/sample6video/pb/m2-res_1080p.mp4?m=DASHPlaylist.mpd")!, kind: .video, group: 1)]
            $0.watched = [WatchedRequest(url: URL(string: "https://v.redd.it/sample6video/CMAF_96.mp4")!, kind: .file)]
        }

        #expect(candidates.count == 1)
        #expect(candidates.first?.versions.compactMap(\.height).filter { $0 > 0 } == [220, 270, 360, 480, 720, 1080])
        #expect(candidates.first?.versions.filter { $0.height == 1080 }.allSatisfy { $0.codecs?.contains("H.264") == true } == true)
    }

    @Test func aPackagedFeedVideoThatIsAlsoPlayingIsListedOnce() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures/Readers/reddit-home-feed.html", withExtension: nil))
        let html = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "{{video}}", with: "sample7video")
            .replacingOccurrences(of: "{{media}}", with: "https://packaged-media.redd.it")
        let page = SitePage(
            url: URL(string: "https://www.reddit.com/")!, html: html,
            media: [URL(string: "https://packaged-media.redd.it/packaged/pb/m2-res_720p.mp4?s=signature")!]
        ) { _ in Data() }

        let videos = try await RedditReader().read(page)

        #expect(videos.map(\.label) == ["feedauthor: A video on the home feed", "packagedauthor: A packaged video"])
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

    @Test func aShortClipPageListsItsHDAndSDFiles() async throws {
        let site = try await ReaderSite { TokenClipReader(api: $0.url(for: "/clips/")) }
        try site.serve(fixture: "clip-token.json", at: "/clips/auth/temporary")
        try site.serve(fixture: "clip-gif.json", at: "/clips/gifs/samplefirstclip", replacing: ["{{media}}": site.url("/media").absoluteString])
        site.site.serve(html: "<title>Clip</title>", at: "/watch/SampleFirstClip")
        site.site.serve(video: 1_500_000, at: "/media/SampleFirstClip.mp4")
        site.site.serve(video: 600_000, at: "/media/SampleFirstClip-mobile.mp4")

        let candidates = try await site.candidates("/watch/SampleFirstClip")

        #expect(candidates.count == 1)
        #expect(candidates.first?.versions.map(\.source.url.lastPathComponent).sorted() == ["SampleFirstClip-mobile.mp4", "SampleFirstClip.mp4"])
        #expect(candidates.first?.versions.compactMap(\.height) == [1080])
    }

    @Test func aShortClipFramePageIsRecognisedAndAnEmbedIsFound() async throws {
        let reader = TokenClipReader()

        #expect(reader.recognises(URL(string: "https://clips.example/ifr/SampleFirstClip")!))
        #expect(reader.post(in: URL(string: "https://clips.example/ifr/SampleFirstClip")!) == "samplefirstclip")
        #expect(!reader.recognises(URL(string: "https://clips.example/browse")!))
        #expect(reader.embeds(in: #"<iframe src="https://clips.example/ifr/SampleFirstClip"></iframe>"#) == [URL(string: "https://clips.example/ifr/samplefirstclip")!])
    }

    @Test func aShortClipTheApiRefusesListsNothingOnReddit() async throws {
        let site = try await reddit()
        try site.serve(fixture: "reddit-feed-clips.html", at: "/r/sample/", replacing: ["{{video}}": "sample8video"])
        try serveRedditVideo(at: "/v/sample8video", on: site)

        let candidates = try await site.candidates("/r/sample/")

        #expect(candidates.map(\.label) == ["thirdauthor: Second clip"])
    }
}
