import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PageAnalyzerTests {
    @Test func aPageWithAnEmbeddedVideoGivesThatVideo() async throws {
        let site = try await Site()
        site.serve(html: """
            <html><head><title>Holiday clip</title></head>
            <body><video src="/media/clip.mp4" poster="/media/poster.jpg"></video></body></html>
            """, at: "/watch")
        site.serve(video: 1000, at: "/media/clip.mp4")

        let found = try await site.analyze("/watch")

        #expect(found == .found([Candidate(
            label: "Holiday clip",
            thumbnail: site.url("/media/poster.jpg"),
            versions: [Version(source: .file(site.url("/media/clip.mp4")), contentType: "video/mp4", totalBytes: 1000)]
        )]))
    }
    @Test func theSourcesOfOnePlayerAreVersionsOfOneVideo() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>HTML Video</title>
            <video controls><source src="/mov_bbb.mp4" type="video/mp4"><source src="/mov_bbb.ogg" type="video/ogg"></video>
            <video><source src="/mov_bbb.mp4" type="video/mp4"><source src="/mov_bbb.ogg" type="video/ogg"></video>
            <audio src="/talk.mp3"></audio>
            """, at: "/html5_video")
        site.serve(video: 788, at: "/mov_bbb.mp4")
        site.serve(video: 600, type: "video/ogg", at: "/mov_bbb.ogg")
        site.serve(video: 50, type: "audio/mpeg", at: "/talk.mp3")

        let found = try await site.analyze("/html5_video")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map { $0.versions.map(\.source.url.lastPathComponent) } == [["mov_bbb.mp4", "mov_bbb.ogg"], ["talk.mp3"]])
    }

    @Test func mediaFilesTheTabRequestedBecomeCandidates() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip page</title><div id=player></div>", at: "/watch")
        site.serve(video: 2_000_000, at: "/stream/clip.mp4")

        let found = try await site.analyze("/watch") {
            $0.watched = [WatchedRequest(url: site.url("/stream/clip.mp4"), kind: .file, contentType: "video/mp4")]
        }

        #expect(found == .found([Candidate(
            label: "Clip page",
            versions: [Version(source: .file(site.url("/stream/clip.mp4")), contentType: "video/mp4", totalBytes: 2_000_000)]
        )]))
    }

    @Test func playlistsTheTabRequestedArentOfferedUntilTheyCanBeDownloaded() async throws {
        let site = try await Site()
        site.serve(html: "<title>Stream</title>", at: "/watch")

        let found = try await site.analyze("/watch") {
            $0.watched = [WatchedRequest(url: site.url("/hls/master.m3u8"), kind: .manifest, contentType: "application/vnd.apple.mpegurl")]
        }

        #expect(found == .found([]))
    }

    @Test func smallFilesFromAnotherSiteAreTakenForAdsUnlessThePageShowsThem() async throws {
        let site = try await Site()
        let other = try await Site()
        site.serve(html: #"<title>Watch</title><video src="\#(other.url("/shown.mp4").absoluteString)"></video>"#, at: "/watch")
        other.serve(video: 300_000, at: "/ad.mp4")
        other.serve(video: 300_000, at: "/shown.mp4")
        other.serve(video: 3_000_000, at: "/long.mp4")
        site.serve(video: 300_000, at: "/own.mp4")

        let found = try await site.analyze("/watch") {
            $0.watched = ["/ad.mp4", "/shown.mp4", "/long.mp4"].map { WatchedRequest(url: other.url($0), kind: .file, contentType: "video/mp4") }
                + [WatchedRequest(url: site.url("/own.mp4"), kind: .file, contentType: "video/mp4")]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(Set(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent)) == ["shown.mp4", "long.mp4", "own.mp4"])
    }

    @Test func aVersionTakesItsResolutionAndCodecFromItsAddress() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/vid/avc1/720x1280/clip.mp4")

        let found = try await site.analyze("/watch") {
            $0.watched = [WatchedRequest(url: site.url("/vid/avc1/720x1280/clip.mp4"), kind: .file, contentType: "video/mp4")]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.first?.versions.first?.height == 720)
        #expect(candidates.first?.versions.first?.codecs == "H.264")
    }

    @Test func downloadLinksTheBrowserFoundAreVersionsOfOneVideoToo() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>Self Checkout</title>
            <a href="/dload/abc/240/1-240p.mp4">Download MP4 (240p, h264, 29.62 MB)</a>
            <a href="/dload/abc/720/1-720p.mp4">Download MP4 (720p, h264, 301.68 MB)</a>
            """, at: "/video-abc/")
        site.serve(video: 300, at: "/dload/abc/240/1-240p.mp4")
        site.serve(video: 900, at: "/dload/abc/720/1-720p.mp4")

        let found = try await site.analyze("/video-abc/") {
            $0.scan = [
                ScannedMedia(url: site.url("/dload/abc/240/1-240p.mp4"), kind: .video),
                ScannedMedia(url: site.url("/dload/abc/720/1-720p.mp4"), kind: .video),
            ]
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
        #expect(candidates.first?.versions.compactMap(\.height).sorted() == [240, 720])
    }

    @Test func aLinkToAPlainFileIsHandedBack() async throws {
        let site = try await Site()
        site.serve(video: 500, type: "application/pdf", at: "/files/report.pdf")

        #expect(try await site.analyze("/files/report.pdf") == .plainFile(site.url("/files/report.pdf")))
    }

    @Test func aLinkStraightToAVideoIsTheOnlyCandidate() async throws {
        let site = try await Site()
        site.serve(video: 800, at: "/media/talk.mp4")

        let found = try await site.analyze("/media/talk.mp4")

        #expect(found == .found([Candidate(
            label: "talk.mp4",
            versions: [Version(source: .file(site.url("/media/talk.mp4")), contentType: "video/mp4", totalBytes: 800)]
        )]))
    }

    @Test func thePageIsReadWithTheBrowsersCookiesAndMediaIsAskedForWithThePageAsReferrer() async throws {
        let site = try await Site()
        var page = TestServer.File(data: Data(#"<video src="/media/clip.mp4"></video>"#.utf8), headers: ["Content-Type": "text/html"])
        page.requiredCookie = "session=abc"
        site.server.serve(page, at: "/members/watch")
        site.serve(video: 300, at: "/media/clip.mp4")

        let found = try await site.analyze("/members/watch") {
            $0.cookies = [Cookie(name: "session", value: "abc")]
            $0.userAgent = "Mozilla/5.0 Dia"
        }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.versions.first?.totalBytes) == [300])
        let media = site.server.requests.filter { $0.path == "/media/clip.mp4" }
        #expect(!media.isEmpty)
        #expect(media.allSatisfy { $0.headers["referer"] == site.url("/members/watch").absoluteString })
        #expect(media.allSatisfy { $0.headers["user-agent"] == "Mozilla/5.0 Dia" })
        #expect(site.server.requests.filter { $0.path == "/members/watch" }.allSatisfy { $0.headers["user-agent"] == "Mozilla/5.0 Dia" })
    }

    @Test func mediaTheBrowserScannedIsProbedAndKept() async throws {
        let site = try await Site()
        site.serve(html: "<html><head><title>Player</title></head><body></body></html>", at: "/player")
        site.serve(video: 640, type: "audio/mp4", at: "/stream/episode.m4a")

        let found = try await site.analyze("/player") {
            $0.scan = [ScannedMedia(url: site.url("/stream/episode.m4a"), kind: .audio, duration: 1800)]
        }

        #expect(found == .found([Candidate(
            label: "Player",
            duration: 1800,
            versions: [Version(source: .file(site.url("/stream/episode.m4a")), contentType: "audio/mp4", totalBytes: 640)]
        )]))
    }

    @Test func mediaThatIsRefusedOrIsAPageIsDropped() async throws {
        let site = try await Site()
        site.serve(html: """
            <video src="/media/refused.mp4"></video>
            <a href="/media/page.mp4">Watch</a>
            <video src="/media/real.mp4"></video>
            """, at: "/watch")
        var refused = TestServer.File(data: Data(count: 10), headers: ["Content-Type": "video/mp4"])
        refused.failFirst = TestServer.StatusFault(status: 403)
        site.server.serve(refused, at: "/media/refused.mp4")
        site.serve(html: "<p>not a video</p>", at: "/media/page.mp4")
        site.serve(video: 90, at: "/media/real.mp4")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).map(\.source) == [.file(site.url("/media/real.mp4"))])
    }

    @Test func aPageWithNothingOnItFindsNothing() async throws {
        let site = try await Site()
        site.serve(html: "<html><body><p>Just words</p><a href=\"/files/a.pdf\">PDF</a></body></html>", at: "/article")

        #expect(try await site.analyze("/article") == .found([]))
    }

    @Test func candidatesAreShownWhileTheyAreStillBeingChecked() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Clip</title><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 50, at: "/media/clip.mp4")

        var updates: [PageAnalysis] = []
        for await update in site.analyzer.analyze(SentPage(url: site.url("/watch"))) { updates.append(update) }

        #expect(updates.first == .looking([Candidate(label: "Clip", versions: [])]))
        #expect(updates.count == 2)
    }

    @Test func aTubeSitesDownloadLinksAndPageDetailsAreRead() async throws {
        let site = try await Site()
        let fixture = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Pages/tube-download-links", withExtension: "html")), encoding: .utf8)
        site.serve(html: fixture, at: "/video-AbCdEfGh123/sample-video/")
        for quality in ["240", "360", "480", "720"] {
            site.serve(video: 100, at: "/dload/AbCdEfGh123/\(quality)/10000001-\(quality)p.mp4")
            site.serve(video: 70, at: "/dload/AbCdEfGh123/\(quality)/10000001-\(quality)p-av1.mp4")
        }

        let found = try await site.analyze("/video-AbCdEfGh123/sample-video/")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
        let video = try #require(candidates.first)
        #expect(video.label == "Sample Video - Performer - TUBE")
        #expect(video.duration == 2405)
        #expect(video.thumbnail == URL(string: "https://static.tube.example/thumbs/10000001/9_240.jpg"))
        #expect(video.versions.count == 8)
        #expect(Set(video.versions.compactMap(\.height)) == [240, 360, 480, 720])
        #expect(video.versions.filter { $0.height == 720 }.compactMap(\.codecs).sorted() == ["AV1", "H.264"])
    }
}

struct Site {
    let server: TestServer
    let analyzer: PageAnalyzer

    init() async throws {
        server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        analyzer = PageAnalyzer { url, options in try await engine.inspect(url, options: options) }
    }

    func url(_ path: String) -> URL { server.url(for: path) }

    func serve(html: String, at path: String) {
        server.serve(TestServer.File(data: Data(html.utf8), headers: ["Content-Type": "text/html; charset=utf-8"]), at: path)
    }

    func serve(video bytes: Int, type: String = "video/mp4", at path: String) {
        server.serve(TestServer.File(data: Data(repeating: 7, count: bytes), headers: ["Content-Type": type]), at: path)
    }

    func analyze(_ path: String, page: (inout SentPage) -> Void = { _ in }) async throws -> PageAnalysis {
        var sent = SentPage(url: url(path))
        page(&sent)
        var last: PageAnalysis?
        for await update in analyzer.analyze(sent) { last = update }
        return try #require(last)
    }
}
