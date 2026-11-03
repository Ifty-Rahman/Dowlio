import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RenderedPageTests {
    @Test func aSiteReaderReadsTheEmbeddedDataOfTheRenderedPage() async throws {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let rendered = try PageFixture.html("instagram-reel")
        let analyzer = PageAnalyzer(
            lookAgain: { _ in PlayedPage(html: rendered) }, readers: [InstagramReader(hosts: ["127.0.0.1"])], readerFailed: { _ in }
        ) { url, options in try await engine.inspect(url, options: options) }
        let site = Site(server: server, analyzer: analyzer)
        site.serve(html: "<title>Instagram</title><div id=root></div>", at: "/reel/Ab12Cd34Ef5/")

        let found = try await site.analyze("/reel/Ab12Cd34Ef5/")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Sample Account: Sample caption for a reel"])
        #expect(!(candidates.first?.versions.isEmpty ?? true))
    }

    @Test func aSiteReaderReadsTheEmbeddedJSONTheScanReturned() async throws {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let reel = PageFixture.json(try PageFixture.embedded("xig_fetch_media", in: "instagram-reel"))
        let analyzer = PageAnalyzer(
            lookAgain: { _ in PlayedPage(embeddedJSON: [reel]) }, readers: [InstagramReader(hosts: ["127.0.0.1"])], readerFailed: { _ in }
        ) { url, options in try await engine.inspect(url, options: options) }
        let site = Site(server: server, analyzer: analyzer)
        site.serve(html: "<title>Instagram</title><div id=root></div>", at: "/reel/Ab12Cd34Ef5/")

        let found = try await site.analyze("/reel/Ab12Cd34Ef5/")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Sample Account: Sample caption for a reel"])
    }

    @Test func theHTMLReaderAndThePageScanReadTheRenderedPage() async throws {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let analyzer = PageAnalyzer(lookAgain: { _ in
            PlayedPage(
                title: "Built in script",
                players: [ScannedPlayer(group: 1, label: "Holiday clip", duration: 12, visibility: 1)],
                scan: [ScannedMedia(url: server.url(for: "/media/scanned.mp4"), kind: .video, group: 1)],
                html: #"<html><body><video src="/media/rendered.mp4"></video></body></html>"#
            )
        }, readers: []) { url, options in try await engine.inspect(url, options: options) }
        let site = Site(server: server, analyzer: analyzer)
        site.serve(html: "<title>Empty</title><div id=app></div>", at: "/watch")
        site.serve(video: 3_000_000, at: "/media/scanned.mp4")
        site.serve(video: 2_000_000, at: "/media/rendered.mp4")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let files = Set(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent))
        #expect(files == ["scanned.mp4", "rendered.mp4"])
        #expect(candidates.map(\.label).contains("Holiday clip"))
    }
}
