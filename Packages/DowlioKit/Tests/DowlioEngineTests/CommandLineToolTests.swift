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

    @Test func aNetworkFailureIsPrintedReadably() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024), failFirst: .init(status: 400)), at: "/bad.zip")
        let folder = try TestFiles.makeFolder()

        let result = try await runTool(["get", server.url(for: "/bad.zip").absoluteString, "-o", folder.path])

        #expect(result.status != 0)
        #expect(result.output.contains("Failed: network error: The server answered with status 400."))
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
        let package = try #require(TestFiles.partialFiles(in: folder).first)

        server.releaseHeldResponses()
        let resumed = try await runTool(["resume", package.path])

        #expect(resumed.status == 0)
        #expect(resumed.output.contains("Completed"))
        #expect(try TestFiles.sha256(of: folder.appending(path: "killed.iso")) == TestFiles.sha256(data))
        #expect(TestFiles.partialFiles(in: folder).isEmpty)
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

        let package = try #require(TestFiles.partialFiles(in: folder).first)
        #expect(result.reason == .exit)
        #expect(result.status == 130)
        let printed = result.output.split(separator: "\n").first { $0.hasPrefix("Paused: ") }?.dropFirst("Paused: ".count)
        let printedPackage = try #require(printed.map { URL(fileURLWithPath: String($0)) })
        #expect(printedPackage.resolvingSymlinksInPath() == package.resolvingSymlinksInPath())
        #expect(savedBytes(in: folder) > 0)
    }
}

extension CommandLineToolTests {
    @Test func checkSitesPrintsWhatEachLinkFoundAndCountsTheLinksThatFoundSomething() async throws {
        let server = try await SiteCheckPages()
        let list = try server.list(["# sample links", "", "/watch", "/empty", "/missing", ""])

        let result = try await runTool(["check-sites", list.path])

        #expect(result.status == 0)
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.contains(server.url("/watch").absoluteString))
        #expect(lines.contains("  Holiday clip"))
        #expect(lines.contains("    file, no resolution, 1,000 bytes"))
        #expect(lines.contains(server.url("/empty").absoluteString))
        #expect(lines.contains("  nothing found, would need Look Again"))
        #expect(lines.contains("  error: notFound"))
        #expect(lines.last == "Found something on 1 of 3 links")
    }

    @Test func checkSitesPrintsJSONToCompareTwoRuns() async throws {
        let server = try await SiteCheckPages()
        let list = try server.list(["/watch", "/empty"])

        let result = try await runTool(["check-sites", list.path, "--json"])

        #expect(result.status == 0)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let links = try #require(report["links"] as? [[String: Any]])
        #expect(links.map { $0["url"] as? String } == [server.url("/watch").absoluteString, server.url("/empty").absoluteString])
        #expect(links.map { $0["result"] as? String } == ["found", "nothing found"])
        let candidates = try #require(links[0]["candidates"] as? [[String: Any]])
        #expect(candidates.map { $0["label"] as? String } == ["Holiday clip"])
        let versions = try #require(candidates[0]["versions"] as? [[String: Any]])
        #expect(versions.map { $0["kind"] as? String } == ["file", "extracted audio"])
        #expect(versions[0]["bytes"] as? Int == 1000)
        #expect(versions[0]["estimated"] as? Bool == false)
        #expect(links[1]["needsLookAgain"] as? Bool == true)
        #expect(report["found"] as? Int == 1)
        #expect(report["total"] as? Int == 2)
    }
}

private struct SiteCheckPages {
    let server: TestServer

    init() async throws {
        server = try await TestServer()
        let page = #"<html><head><title>Holiday clip</title></head><body><video src="/clip.mp4"></video></body></html>"#
        server.serve(.init(data: Data(page.utf8), headers: ["Content-Type": "text/html; charset=utf-8"]), at: "/watch")
        server.serve(.init(data: Data("<title>Nothing here</title>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"]), at: "/empty")
        server.serve(.init(data: Data(repeating: 7, count: 1000), headers: ["Content-Type": "video/mp4"]), at: "/clip.mp4")
    }

    func url(_ path: String) -> URL { server.url(for: path) }

    func list(_ lines: [String]) throws -> URL {
        let file = try TestFiles.makeFolder().appending(path: "sites.txt")
        let text = lines.map { $0.hasPrefix("/") ? url($0).absoluteString : $0 }.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        return file
    }
}

private final class BundleMarker {}

private struct ToolResult {
    let status: Int32
    let reason: Process.TerminationReason
    let output: String
}

/// The bytes the saved manifest of the partial file in `folder` records, or 0 before a save.
private func savedBytes(in folder: URL) -> Int64 {
    guard let package = TestFiles.partialFiles(in: folder).first,
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
    let exited = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in exited.continuation.finish() }
    try process.run()

    var output = ""
    for await line in lines(of: pipe.fileHandleForReading) {
        output += line + "\n"
        onLine(line, process)
    }
    for await _ in exited.stream {}
    return ToolResult(status: process.terminationStatus, reason: process.terminationReason, output: output)
}
