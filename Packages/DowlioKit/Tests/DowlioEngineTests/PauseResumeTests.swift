import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PauseResumeTests {
    static let size = 4 * 1024 * 1024
    static let held = 256 * 1024

    @Test func pauseStopsEveryConnectionAndResumeFetchesOnlyTheMissingBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 31)
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"v1\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/big.iso")

        await engine.pause(id)
        let paused = try await engine.firstSnapshot(of: id) { _ in true }
        #expect(paused.state == .paused)
        #expect(paused.activeConnections == 0)
        #expect(paused.receivedBytes == Int64(2 * Self.held))

        // Nothing more is asked for or received while paused, even once the server could send
        // more. Another whole download through the same engine and server comes first, so the
        // check follows real requests rather than a fixed wait.
        let requestsWhenPaused = server.requests.count { $0.path == "/big.iso" }
        server.releaseHeldResponses()
        try await engine.runOtherDownload(on: server)
        #expect(server.requests.count { $0.path == "/big.iso" } == requestsWhenPaused)
        let stillPaused = try await engine.firstSnapshot(of: id) { _ in true }
        #expect(stillPaused.state == .paused)
        #expect(stillPaused.receivedBytes == Int64(2 * Self.held))

        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "big.iso")) == TestFiles.sha256(data))
        // Resume sends exactly one probe, then asks for each segment's missing part once.
        let resumed = server.requests.filter { $0.path == "/big.iso" }.dropFirst(requestsWhenPaused)
            .map { $0.headers["range"] }
        let missing = Set(paused.segments.map { "bytes=\($0.start + $0.receivedBytes)-\($0.end)" })
        #expect(resumed.first == "bytes=0-0")
        #expect(paused.segments.count == 2)
        #expect(missing.isSubset(of: Set(resumed.dropFirst().compactMap { $0 })))
    }

    @Test func theManifestOnDiskDescribesTheDownloadAndNeverLeadsTheData() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 32)
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"m1\"")
        var options = RequestOptions()
        options.referrer = URL(string: "https://example.com/page")
        options.userAgent = "DowlioTest/2.0"
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/disk.img", options: options)
        let package = folder.appending(path: "disk.img.dowlio")

        // Saved about once a second while downloading.
        try await waitUntil { (try? Self.manifestReceived(in: package)) == Int64(2 * Self.held) }
        try Self.checkManifest(in: package, id: id, server: server, data: data)

        // Saved again when the download pauses.
        await engine.pause(id)
        let manifest = try Self.manifest(in: package)
        #expect(manifest["fileName"] as? String == "disk.img")
        #expect(try Self.manifestReceived(in: package) == Int64(2 * Self.held))
        try Self.checkManifest(in: package, id: id, server: server, data: data)
    }

    @Test func theManifestIsSavedWhenTheDownloadStartsRetrying() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 38)
        server.serve(.init(data: data, eTag: "\"w1\"", dropFirst: .init(afterBytes: 1024 * 1024, count: 1)), at: "/wait.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 1
        // The wait outlasts the test, so the download is still Retrying when the manifest is read.
        var configuration = EngineConfiguration.fast
        configuration.retry.firstDelay = .seconds(30)
        configuration.retry.maximumDelay = .seconds(30)

        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/wait.bin"), to: folder, options: options)
        _ = try await engine.firstSnapshot(of: id) { if case .retrying = $0.state { true } else { false } }

        #expect(try Self.manifestReceived(in: folder.appending(path: "wait.bin.dowlio")) > 0)
        await engine.cancel(id)
    }

    private static func manifest(in package: URL) throws -> [String: Any] {
        let json = try Data(contentsOf: package.appending(path: "manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private static func manifestReceived(in package: URL) throws -> Int64 {
        let segments = try manifest(in: package)["segments"] as? [[String: Any]] ?? []
        return segments.reduce(0) { $0 + (($1["received"] as? NSNumber)?.int64Value ?? 0) }
    }

    /// Checks every field the manifest holds, that no cookie is stored, and that each segment's
    /// received count never exceeds the bytes actually in the data file.
    private static func checkManifest(in package: URL, id: DownloadID, server: TestServer, data: Data) throws {
        let manifest = try manifest(in: package)
        #expect(manifest["formatVersion"] as? Int == 3)
        #expect(manifest["nameConflictPolicy"] as? String == "keepBoth")
        #expect(manifest["downloadID"] as? String == id.description)
        #expect(manifest["originalURL"] as? String == server.url(for: "/disk.img").absoluteString)
        #expect(manifest["finalURL"] as? String == server.url(for: "/disk.img").absoluteString)
        #expect(manifest["validator"] as? String == "\"m1\"")
        #expect((manifest["totalBytes"] as? NSNumber)?.intValue == data.count)
        #expect(manifest["connections"] as? Int == 2)
        #expect(manifest["referrer"] as? String == "https://example.com/page")
        #expect(manifest["userAgent"] as? String == "DowlioTest/2.0")
        #expect(!manifest.keys.contains { $0.lowercased().contains("cookie") })

        let written = try Data(contentsOf: package.appending(path: "data"))
        let segments = try #require(manifest["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        for segment in segments {
            let start = try #require((segment["start"] as? NSNumber)?.intValue)
            let end = try #require((segment["end"] as? NSNumber)?.intValue)
            let received = try #require((segment["received"] as? NSNumber)?.intValue)
            #expect(received <= end - start + 1)
            #expect(written.count >= start + received)
            #expect(written.subdata(in: start..<(start + received)) == data.subdata(in: start..<(start + received)))
        }
    }

    @Test func resumeAsksForTheOriginalLinkAgain() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 33)
        server.redirect("/latest", to: "/v1.bin")
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"r1\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/v1.bin", start: "/latest")

        await engine.pause(id)
        let requestsWhenPaused = server.requests.count
        server.releaseHeldResponses()
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(server.requests[requestsWhenPaused].path == "/latest")
        #expect(try TestFiles.sha256(of: folder.appending(path: "v1.bin")) == TestFiles.sha256(data))
    }

    @Test func resumeUsesTheLastFinalLinkWhenTheOriginalIsGone() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 34)
        server.redirect("/once", to: "/signed.bin")
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"s1\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/signed.bin", start: "/once")

        await engine.pause(id)
        server.remove("/once")
        let requestsWhenPaused = server.requests.count
        server.releaseHeldResponses()
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        let afterPause = server.requests[requestsWhenPaused...].map(\.path)
        #expect(afterPause.first == "/once")
        #expect(afterPause.dropFirst().allSatisfy { $0 == "/signed.bin" })
        // The segments were kept: no request starts the file again from byte 0 except the probe.
        #expect(!server.requests[requestsWhenPaused...].contains { $0.headers["range"]?.hasPrefix("bytes=0-") == true && $0.headers["range"] != "bytes=0-0" })
        #expect(try TestFiles.sha256(of: folder.appending(path: "signed.bin")) == TestFiles.sha256(data))
    }

    @Test func resumeFailsAsLinkExpiredWhenNeitherLinkWorks() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 35)
        server.redirect("/once", to: "/signed.bin")
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"s2\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/signed.bin", start: "/once")

        await engine.pause(id)
        server.remove("/once")
        server.remove("/signed.bin")
        server.releaseHeldResponses()
        await engine.resume(id)
        let failed = try await engine.completedOrFailed(id)

        #expect(failed.state == .failed(.linkExpired))
        #expect(failed.receivedBytes == Int64(2 * Self.held))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "signed.bin.dowlio").path))
    }

    @Test func aFileChangedWhilePausedStartsOverAndNeverMixesVersions() async throws {
        let server = try await TestServer()
        let old = TestServer.makeData(size: Self.size, seed: 36)
        let new = TestServer.makeData(size: Self.size, seed: 37)
        let file = TestServer.File(data: old, holdAfterBytes: Self.held, eTag: "\"old\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/report.pdf")

        await engine.pause(id)
        server.serve(.init(data: new, eTag: "\"new\""), at: "/report.pdf")
        server.releaseHeldResponses()
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "report.pdf")) == TestFiles.sha256(new))
    }

    @Test(arguments: [nil, "W/\"weak\""] as [String?])
    func withoutAStrongValidatorResumeStartsOver(eTag: String?) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 38)
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: eTag)
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/notes.zip")

        await engine.pause(id)
        let requestsWhenPaused = server.requests.count
        server.releaseHeldResponses()
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "notes.zip")) == TestFiles.sha256(data))
        // A changed file can't be detected, so the download starts again from byte 0 and splits
        // again.
        let resumedStarts = Set(server.requests[requestsWhenPaused...].compactMap { request -> Int? in
            guard let range = request.headers["range"], range != "bytes=0-0" else { return nil }
            return Int(range.dropFirst("bytes=".count).prefix { $0 != "-" })
        })
        #expect(resumedStarts.contains(0))
        #expect(resumedStarts.count >= 2)
    }

    @Test func aFileChangedMidDownloadStartsOverOnce() async throws {
        let server = try await TestServer()
        let old = TestServer.makeData(size: Self.size, seed: 39)
        let new = TestServer.makeData(size: Self.size, seed: 40)
        // The probe and the first segment's request see the old file. The second segment's
        // request, sent with If-Range "old", gets the new file with 200.
        server.serve(.init(data: old, eTag: "\"old\"", changeAfter: .init(afterRequests: 2, data: new, eTag: "\"new\"")), at: "/build.zip")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/build.zip"), to: folder, options: options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "build.zip")) == TestFiles.sha256(new))
    }

    @Test func aFileThatKeepsChangingFailsAsServerChangedFile() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: Self.size, seed: 41), newETagEveryRequest: true), at: "/live.log")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/live.log"), to: folder, options: options)
        let failed = try await engine.completedOrFailed(id)

        #expect(failed.state == .failed(.serverChangedFile))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "live.log").path))
    }

    @Test(arguments: [true, false])
    func snapshotsSayWhetherTheDownloadCanResume(rangesSupported: Bool) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 42)
        server.serve(.init(data: data, supportsRanges: rangesSupported, holdAfterBytes: 64 * 1024, eTag: "\"c\""), at: "/c.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/c.bin"), to: folder)
        let downloading = try await engine.firstSnapshot(of: id) { $0.receivedBytes > 0 }

        #expect(downloading.canResume == rangesSupported)
        server.releaseHeldResponses()
        _ = try await engine.completedOrFailed(id)
    }

    @Test func everyRequestSendsTheReferrerAndUserAgent() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 3 * 1024 * 1024), eTag: "\"a\""), at: "/page-file.zip")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 3
        options.referrer = URL(string: "https://example.com/downloads")
        options.userAgent = "DowlioTest/1.0"

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/page-file.zip"), to: folder, options: options)
        _ = try await engine.completedOrFailed(id)

        #expect(server.requests.count >= 2)
        #expect(server.requests.allSatisfy { $0.headers["referer"] == "https://example.com/downloads" })
        #expect(server.requests.allSatisfy { $0.headers["user-agent"] == "DowlioTest/1.0" })
    }
}
