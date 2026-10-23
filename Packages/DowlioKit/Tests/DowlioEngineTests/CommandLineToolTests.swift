import DowlioTestSupport
import Foundation
import Testing

/// Smoke tests for `dowlio-cli`, run as a separate process.
@Suite(.timeLimit(.minutes(1)))
struct CommandLineToolTests {
    @Test func getDownloadsTheFileAndExitsWithZero() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 11)
        server.serve(.init(data: data), at: "/tool.dmg")
        let folder = try TestFiles.makeFolder()

        let result = try await runTool(["get", server.url(for: "/tool.dmg").absoluteString, "-o", folder.path])

        #expect(result.status == 0)
        #expect(try TestFiles.sha256(of: folder.appending(path: "tool.dmg")) == TestFiles.sha256(data))
        #expect(result.output.contains("Completed"))
    }

    @Test func getPrintsAProgressLineEverySecondWhileStalled() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 12)
        server.serve(.init(data: data, holdAfterBytes: 512 * 1024), at: "/slow.zip")
        let folder = try TestFiles.makeFolder()

        // The response stalls at 25 percent for about two seconds, then finishes.
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            server.releaseHeldResponses()
        }
        let result = try await runTool(["get", server.url(for: "/slow.zip").absoluteString, "-o", folder.path])

        #expect(result.status == 0)
        let stalledLines = result.output.split(separator: "\n").filter { $0.hasPrefix("25%") }
        #expect(stalledLines.count >= 2)
    }

    @Test func getExitsWithNonZeroWhenTheDownloadFails() async throws {
        let server = try await TestServer()
        let folder = try TestFiles.makeFolder()

        let result = try await runTool(["get", server.url(for: "/missing.zip").absoluteString, "-o", folder.path])

        #expect(result.status != 0)
        #expect(result.output.contains("Failed"))
    }

    @Test func noArgumentsPrintsUsageAndExitsWithNonZero() async throws {
        let result = try await runTool([])

        #expect(result.status != 0)
        #expect(result.output.contains("usage"))
    }
}

private final class BundleMarker {}

private struct ToolResult {
    let status: Int32
    let output: String
}

/// Runs the `dowlio-cli` built next to this test bundle.
private func runTool(_ arguments: [String]) async throws -> ToolResult {
    let tool = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent()
        .appending(path: "dowlio-cli")
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = try await Task.detached {
        try pipe.fileHandleForReading.readToEnd() ?? Data()
    }.value
    process.waitUntilExit()
    return ToolResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
}
