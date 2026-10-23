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

        // The response stalls at 25 percent. The server lets it finish only after the tool has
        // printed two progress lines during the stall, so a tool that stops printing hangs here.
        var stalledLines = 0
        let result = try await runTool(["get", server.url(for: "/slow.zip").absoluteString, "-o", folder.path]) { line in
            guard line.hasPrefix("25%") else { return }
            stalledLines += 1
            if stalledLines == 2 { server.releaseHeldResponses() }
        }

        #expect(result.status == 0)
        #expect(stalledLines >= 2)
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

/// The lines written to `handle`, read on a background thread until the writer closes it.
private func lines(of handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
            if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
            continuation.finish()
        }
    }
}

/// Runs the `dowlio-cli` built next to this test bundle. `onLine` sees each output line as it
/// arrives.
private func runTool(_ arguments: [String], onLine: (String) -> Void = { _ in }) async throws -> ToolResult {
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

    var output = ""
    for await line in lines(of: pipe.fileHandleForReading) {
        output += line + "\n"
        onLine(line)
    }
    process.waitUntilExit()
    return ToolResult(status: process.terminationStatus, output: output)
}
