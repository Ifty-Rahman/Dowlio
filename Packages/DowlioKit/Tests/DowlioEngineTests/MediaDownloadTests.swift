import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MediaDownloadTests {
    private func serve(_ count: Int, on server: TestServer, hold: Bool, origin: String? = nil) -> MediaSource {
        let fragments = (0..<count).map { index in
            let path = "/clip/seg\(index).ts"
            server.serve(TestServer.File(data: TestServer.makeData(size: 4096, seed: UInt64(index + 1)), holdAfterBytes: hold ? 0 : nil, requiredOrigin: origin), at: path)
            return MediaFragment(url: server.url(for: path))
        }
        return try! MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])
    }

    @Test func withoutAWayToMakeAnMP4TheDownloadFailsInsteadOfSavingRawSegments() async throws {
        let server = try await TestServer()
        let folder = try TestFiles.makeFolder()
        let engine = DownloadEngine(configuration: .fast)

        let id = await engine.add(source: .media(serve(3, on: server, hold: false)), destination: .folder(folder))
        let ended = try await engine.completedOrFailed(id)

        #expect(ended.state == .failed(.mediaUnplayable))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "seg0.mp4").path))
    }

    @Test func segmentsKeepToTheLimitLearnedForTheirHost() async throws {
        let server = try await TestServer()
        let folder = try TestFiles.makeFolder()
        let limits = InMemoryHostLimitStore()
        limits.updateLimit(for: "127.0.0.1:\(server.port)") { _ in 1 }
        var configuration = EngineConfiguration.fast
        configuration.hostLimits = limits
        let engine = DownloadEngine(configuration: configuration)
        let media = serve(4, on: server, hold: true)
        let paths = media.tracks[0].fragments.map(\.url.path)
        let open: @Sendable () -> Int = { paths.map { server.openConnections(at: $0) }.reduce(0, +) }
        var options = RequestOptions()
        options.connections = 4

        let id = await engine.add(source: .media(media), destination: .folder(folder), options: options)
        try await waitUntil { open() == 1 }
        try await Task.sleep(for: .milliseconds(200))
        let peak = open()
        await engine.cancel(id)

        #expect(peak == 1)
    }

    @Test func segmentsFromAnotherSiteAreAskedForWithTheOriginOfThePlayerThatPlayedThem() async throws {
        let server = try await TestServer()
        let folder = try TestFiles.makeFolder()
        let engine = DownloadEngine(configuration: .fast)
        var options = RequestOptions()
        options.referrer = URL(string: "https://player.example/e/abc")

        let id = await engine.add(source: .media(serve(3, on: server, hold: false, origin: "https://player.example")), destination: .folder(folder), options: options)
        let ended = try await engine.completedOrFailed(id)

        #expect(ended.state == .failed(.mediaUnplayable))
    }
}
