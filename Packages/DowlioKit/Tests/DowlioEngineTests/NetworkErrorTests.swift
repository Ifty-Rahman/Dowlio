import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// A network failure keeps the underlying error (spec, errors).
@Suite(.timeLimit(.minutes(1)))
struct NetworkErrorTests {
    @Test func aNetworkFailureKeepsTheURLErrorCode() async throws {
        let server = try await TestServer()
        server.redirect("/odd", to: "nope://127.0.0.1/file.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/odd"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        guard case .failed(.network(let failure)) = finished.state else {
            Issue.record("Expected a network failure, got \(finished.state)")
            return
        }
        #expect(failure.code == .unsupportedURL)
        #expect(!failure.message.isEmpty)
    }

    @Test func anUnexpectedStatusIsABadServerResponseNamingTheStatus() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024), failFirst: .init(status: 400)), at: "/bad.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/bad.zip"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        guard case .failed(.network(let failure)) = finished.state else {
            Issue.record("Expected a network failure, got \(finished.state)")
            return
        }
        #expect(failure.code == .badServerResponse)
        #expect(failure.message.contains("400"))
    }
}
