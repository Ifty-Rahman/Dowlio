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
        let result = try await runTool(["get", server.url(for: "/slow.zip").absoluteString, "-c", "1", "-o", folder.path]) { line, _ in
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

extension CommandLineToolTests {
    @Test func resumeFinishesADownloadAfterTheToolWasKilled() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 13)
        server.serve(.init(data: data, holdAfterBytes: 256 * 1024, eTag: "\"v1\""), at: "/killed.iso")
        let folder = try TestFiles.makeFolder()

        // The tool is killed once its partial file's manifest records bytes, as a crash would.
        let killed = try await runTool(["get", server.url(for: "/killed.iso").absoluteString, "-o", folder.path]) { _, process in
            if savedBytes(in: folder) > 0 { kill(process.processIdentifier, SIGKILL) }
        }
        #expect(killed.reason == .uncaughtSignal)
        let package = try #require(partialFiles(in: folder).first)

        server.releaseHeldResponses()
        let resumed = try await runTool(["resume", package.path])

        #expect(resumed.status == 0)
        #expect(resumed.output.contains("Completed"))
        #expect(try TestFiles.sha256(of: folder.appending(path: "killed.iso")) == TestFiles.sha256(data))
        #expect(partialFiles(in: folder).isEmpty)
    }

    @Test func ctrlCPausesTheDownloadAndPrintsItsPartialFile() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 14)
        server.serve(.init(data: data, holdAfterBytes: 256 * 1024, eTag: "\"v1\""), at: "/stopped.iso")
        let folder = try TestFiles.makeFolder()

        // Ctrl-C arrives once a progress line shows bytes.
        var interrupted = false
        let result = try await runTool(["get", server.url(for: "/stopped.iso").absoluteString, "-o", folder.path]) { line, process in
            guard !interrupted, line.contains("%"), !line.hasPrefix("0%") else { return }
            interrupted = true
            process.interrupt()
        }

        let package = try #require(partialFiles(in: folder).first)
        #expect(result.reason == .exit)
        #expect(result.status == 130)
        let printed = result.output.split(separator: "\n").first { $0.hasPrefix("Paused: ") }?.dropFirst("Paused: ".count)
        let printedPackage = try #require(printed.map { URL(fileURLWithPath: String($0)) })
        #expect(printedPackage.resolvingSymlinksInPath() == package.resolvingSymlinksInPath())
        #expect(savedBytes(in: folder) > 0)
    }
}

private final class BundleMarker {}

private struct ToolResult {
    let status: Int32
    let reason: Process.TerminationReason
    let output: String
}

/// The partial files in `folder`.
private func partialFiles(in folder: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "dowlio" }
}

/// The bytes the saved manifest of the partial file in `folder` records, or 0 before a save.
private func savedBytes(in folder: URL) -> Int64 {
    guard let package = partialFiles(in: folder).first,
          let data = try? Data(contentsOf: package.appending(path: "manifest.json")),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let segments = manifest["segments"] as? [[String: Any]] else { return 0 }
    return segments.reduce(0) { $0 + ((($1["received"] as? NSNumber)?.int64Value) ?? 0) }
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
/// arrives, with the running process, so a test can send it a signal.
private func runTool(_ arguments: [String], onLine: (String, Process) -> Void = { _, _ in }) async throws -> ToolResult {
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
        onLine(line, process)
    }
    process.waitUntilExit()
    return ToolResult(status: process.terminationStatus, reason: process.terminationReason, output: output)
}
