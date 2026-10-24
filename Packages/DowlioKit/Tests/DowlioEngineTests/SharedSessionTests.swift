import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SharedSessionTests {
    @Test func oneSharedSessionRunsSixteenConnectionsAtOnce() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 16 * 1024 * 1024, seed: 91)
        server.serve(.init(data: data, holdAfterBytes: 64 * 1024, maxParallel: 32), at: "/shared.iso")
        let folder = try TestFiles.makeFolder()
        var configuration = EngineConfiguration.fast
        configuration.sessions = .oneShared
        var options = RequestOptions()
        options.connections = 16

        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/shared.iso"), to: folder, options: options)
        // Every reply holds, so the wait ends only once all 16 are in flight together.
        try await waitUntil { server.peakParallel(at: "/shared.iso") == 16 }
        server.releaseHeldResponses()
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "shared.iso")) == TestFiles.sha256(data))
    }
}
