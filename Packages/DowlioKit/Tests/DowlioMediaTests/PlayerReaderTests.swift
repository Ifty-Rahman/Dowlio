import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlayerReaderTests {
    private func players() async throws -> ReaderSite {
        try await ReaderSite { server in
            [JWPlayerReader(api: server.url(for: "/")), WebPlayerReader.videoJS, WebPlayerReader.plyr, WebPlayerReader.flowplayer, WebPlayerReader.clappr]
        }
    }

    private func page(_ name: String, on site: ReaderSite, at path: String) throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Players/\(name)", withExtension: nil))
        let server = String(site.url("/").absoluteString.dropLast())
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "{{server}}", with: server).replacingOccurrences(of: "{{api}}", with: server)
            .replacingOccurrences(of: "{{host}}", with: site.url("/").host()! + ":\(site.url("/").port!)")
        let type = name.hasSuffix(".json") ? "application/json" : "text/html; charset=utf-8"
        site.site.server.serve(TestServer.File(data: Data(text.utf8), headers: ["Content-Type": type]), at: path)
    }

    private func serveStream(at path: String, on site: ReaderSite) {
        let folder = (path as NSString).deletingLastPathComponent
        site.site.serve(text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS=\"avc1.64001f,mp4a.40.2\"\nv.m3u8\n", at: path)
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "s"), at: "\(folder)/v.m3u8")
        for index in 0..<2 { site.site.serve(video: 100_000, type: "video/mp2t", at: "\(folder)/s\(index).ts") }
    }

    @Test func jwPlayerSetupGivesItsSourcesWithTheTitlePosterAndLength() async throws {
        let site = try await players()
        try page("jwplayer-setup.html", on: site, at: "/news/field-notes")
        serveStream(at: "/media/field-notes/master.m3u8", on: site)
        site.site.serve(video: 4_000_000, at: "/media/field-notes/720.mp4")
        site.site.serve(video: 2_000_000, at: "/media/field-notes/360.mp4")

        let candidates = try await site.candidates("/news/field-notes")

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Field notes: a day at the station")
        #expect(video.thumbnail == site.url("/thumbs/field-notes.jpg"))
        #expect(video.duration == 94)
        #expect(Set(video.versions.compactMap(\.height)) == [360, 720])
        #expect(video.versions.contains { if case .media = $0.source { true } else { false } })
    }

    @Test func aHostedJWPlayerMediaIDIsReadFromItsMediaReply() async throws {
        let site = try await players()
        try page("jwplayer-hosted.html", on: site, at: "/clip")
        try page("jwplayer-media.json", on: site, at: "/v2/media/Xy12Ab34")
        serveStream(at: "/manifests/Xy12Ab34.m3u8", on: site)
        site.site.serve(video: 5_000_000, at: "/videos/Xy12Ab34-720.mp4")
        site.site.serve(video: 500_000, type: "audio/mp4", at: "/videos/Xy12Ab34-180.m4a")

        let candidates = try await site.candidates("/clip")

        let video = try #require(candidates.first)
        #expect(video.label == "Harbour at dawn")
        #expect(video.duration == 61)
        #expect(video.thumbnail == site.url("/v2/media/Xy12Ab34/poster.jpg"))
        #expect(video.versions.contains { $0.height == 720 })
        #expect(video.versions.contains { $0.isAudio })
    }

    @Test func videoJSReadsItsDataSetupAndItsVideoJSElement() async throws {
        let site = try await players()
        try page("videojs.html", on: site, at: "/lecture")
        serveStream(at: "/streams/lecture4/index.m3u8", on: site)
        site.site.serve(video: 6_000_000, at: "/files/extra-1080.mp4")
        site.site.serve(video: 3_000_000, at: "/files/extra-480.mp4")

        let candidates = try await site.candidates("/lecture")

        let heights = Set(candidates.flatMap(\.versions).compactMap(\.height))
        #expect(heights.isSuperset(of: [480, 720, 1080]))
        #expect(candidates.contains { $0.thumbnail == site.url("/posters/extra.jpg") })
    }

    @Test func plyrFlowplayerAndClapprReadTheirSetupObjects() async throws {
        let site = try await players()
        try page("plyr.html", on: site, at: "/tour")
        try page("flowplayer.html", on: site, at: "/highlights")
        try page("clappr.html", on: site, at: "/archive")
        site.site.serve(video: 2_000_000, at: "/videos/tour-576.mp4")
        site.site.serve(video: 4_000_000, at: "/videos/tour-1080.mp4")
        serveStream(at: "/hls/highlights/playlist.m3u8", on: site)
        site.site.serve(video: 3_000_000, at: "/mp4/highlights.mp4")
        serveStream(at: "/archive/2026-10-01/playlist.m3u8", on: site)

        let tour = try await site.candidates("/tour")
        let highlights = try await site.candidates("/highlights")
        let archive = try await site.candidates("/archive")

        #expect(tour.map(\.label) == ["Product tour 2026"])
        #expect(Set(tour.flatMap(\.versions).compactMap(\.height)) == [576, 1080])
        #expect(tour.first?.thumbnail == site.url("/videos/tour.jpg"))
        #expect(highlights.map(\.label) == ["Match highlights"])
        #expect(highlights.flatMap(\.versions).count == 2)
        #expect(archive.first?.thumbnail == site.url("/archive/2026-10-01/poster.jpg"))
        #expect(archive.flatMap(\.versions).map(\.height) == [720])
    }

    @Test func aPlayerReaderThatFindsNothingIsLoggedAndThePageIsStillRead() async throws {
        let site = try await players()
        site.site.serve(html: #"<title>Broken</title><script>jwplayer("p").setup({ width: 640 });</script><video src="/media/own.mp4"></video>"#, at: "/broken")
        site.site.serve(video: 2_000_000, at: "/media/own.mp4")

        let candidates = try await site.candidates("/broken")

        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["own.mp4"])
        #expect(site.log.failures.map(\.reader) == ["JW Player"])
    }
}
