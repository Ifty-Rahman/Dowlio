import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// A file whose size the server doesn't report, such as a streamed or generated one (story 4).
@Suite(.timeLimit(.minutes(1)))
struct UnknownSizeTests {
    @Test func aFileOfUnknownSizeDownloadsOverOneConnection() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 3 * 1024 * 1024, seed: 81)
        let held = 256 * 1024
        server.serve(.init(data: data, holdAfterBytes: held, eTag: "\"u1\"", omitsLength: true), at: "/stream.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: "/stream.bin"), to: folder)
        let midway = try await engine.firstSnapshot(of: id) { $0.receivedBytes >= Int64(held) }

        #expect(midway.state == .downloading)
        #expect(midway.totalBytes == nil)
        #expect(midway.segments.isEmpty)
        #expect(!midway.canResume)

        server.releaseHeldResponses()
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(finished.receivedBytes == Int64(data.count))
        #expect(try TestFiles.sha256(of: folder.appending(path: "stream.bin")) == TestFiles.sha256(data))
        // The probe's own reply carried the whole file.
        #expect(server.requests.count == 1)
    }
}
