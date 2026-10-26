import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// answers 416 with `Content-Range: bytes */0`. A server without ranges answers 200 with no body.
@Suite(.timeLimit(.minutes(1)))
struct EmptyFileTests {
    @Test(arguments: [true, false])
    func anEmptyFileCompletesAsAnEmptyFile(rangesSupported: Bool) async throws {
        let server = try await TestServer()
        server.serve(.init(data: Data(), supportsRanges: rangesSupported, eTag: "\"e0\""), at: "/empty.txt")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/empty.txt"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.totalBytes == 0)
        #expect(finished.receivedBytes == 0)
        #expect(finished.segments.isEmpty)
        #expect(try Data(contentsOf: folder.appending(path: "empty.txt")).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["empty.txt"])
        #expect(server.requests.count == 1)
    }
}
