import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YTDLPPathTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    private func candidate(printing json: String? = nil, fixture: String? = nil, framedBy: URL? = nil) async throws -> Candidate {
        let standIn: YTDLPStandIn
        if let json {
            let file = try TestFiles.makeFolder().appending(path: "listing.json")
            try json.write(to: file, atomically: true, encoding: .utf8)
            standIn = try await YTDLPStandIn.install(script: "cat '\(file.path)'")
        } else {
            standIn = try await YTDLPStandIn.printing(fixture ?? "")
        }
        let engine = DownloadEngine(configuration: .fast)
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer), decodesAV1: true) { url, options in
            try await engine.inspect(url, options: options)
        }
        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: watch, framedBy: framedBy)) { last = update }
        guard case .found(let candidates)? = last, let first = candidates.first else { throw FoundNothing() }
        return first
    }

    private struct FoundNothing: Error {}

    private func media(_ version: Version?) throws -> MediaSource {
        guard case .media(let media)? = version?.source else { throw FoundNothing() }
        return media
    }

    @Test func aResolutionNoOtherPathCanReachIsDownloadedByYTDLPItself() async throws {
        let video = try await candidate(fixture: "derived-video-sabr-only-1440.json")

        let row = try #require(video.versions.first { $0.height == 1440 })
        let source = try media(row)
        #expect(source.downloadsWithYTDLP)
        #expect(row.renewal?.formatIDs == ["400", "140"])
        #expect(row.outputContainer == .mp4)
        #expect(video.versions.filter { $0.height != 1440 }.allSatisfy { (try? media($0).downloadsWithYTDLP) == false })
    }

    @Test func anHLSFormatDownloadsThroughTheHLSPathWithYTDLPsHeaders() async throws {
        let server = try await TestServer()
        let playlist = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/hls-media-ts", withExtension: "m3u8")), encoding: .utf8)
        server.serve(TestServer.File(data: Data(playlist.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"]), at: "/hls/720.m3u8")
        let json = """
            {"title": "Talk", "formats": [
              {"format_id": "hls-720", "height": 720, "vcodec": "avc1.64001f", "acodec": "mp4a.40.2", "protocol": "m3u8_native",
               "url": "\(server.url(for: "/hls/720.m3u8"))", "http_headers": {"User-Agent": "Talk Agent"}},
              {"format_id": "aac", "vcodec": "none", "acodec": "mp4a.40.2", "protocol": "https", "url": "\(server.url(for: "/a.m4a"))", "filesize": 10}
            ]}
            """

        let video = try await candidate(printing: json, framedBy: server.url(for: "/"))

        let row = try #require(video.versions.first { $0.height == 720 })
        let source = try media(row)
        #expect(!source.downloadsWithYTDLP)
        #expect(source.tracks.first?.fragments.count == 100)
        #expect(source.tracks.first?.fragments.first?.url == server.url(for: "/hls/fileSequence0.ts"))
        #expect(server.requests.first { $0.path == "/hls/720.m3u8" }?.headers["user-agent"] == "Talk Agent")
    }

    @Test func aDASHFormatDownloadsItsListedFragments() async throws {
        let json = """
            {"title": "Clip", "formats": [
              {"format_id": "dash-720", "height": 720, "vcodec": "avc1.64001f", "acodec": "none", "protocol": "http_dash_segments",
               "url": "https://cdn.example/manifest.mpd", "fragment_base_url": "https://cdn.example/video/",
               "fragments": [{"path": "init.mp4"}, {"path": "seg-1.m4s"}, {"url": "https://cdn.example/other/seg-2.m4s"}]},
              {"format_id": "aac", "vcodec": "none", "acodec": "mp4a.40.2", "protocol": "https", "url": "https://cdn.example/a.m4a", "filesize": 10}
            ]}
            """

        let video = try await candidate(printing: json)

        let source = try media(video.versions.first { $0.height == 720 })
        #expect(source.tracks.first?.fragments.map(\.url.absoluteString) == [
            "https://cdn.example/video/init.mp4", "https://cdn.example/video/seg-1.m4s", "https://cdn.example/other/seg-2.m4s",
        ])
    }

    @Test func httpsStaysFirstWhenAResolutionAlsoHasHLS() async throws {
        let video = try await candidate(fixture: "video-4k.json")

        let rows = video.versions.filter { !$0.isAudio }
        #expect(rows.allSatisfy { row in
            guard let source = try? media(row) else { return false }
            return !source.downloadsWithYTDLP && source.tracks.allSatisfy { $0.fragments.count == 1 }
        })
    }
}
