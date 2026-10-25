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
        // Resume's first request is the first segment's missing part. Each segment's missing part
        // is asked for from its first missing byte, with the validator. A new connection may split
        // a segment before its own request goes out, so a request may end early, but never asks
        // for bytes the download has.
        let resumed = Array(server.requests.filter { $0.path == "/big.iso" }.dropFirst(requestsWhenPaused))
        let first = try #require(paused.segments.first)
        #expect(resumed.first?.headers["range"] == "bytes=\(first.start + first.receivedBytes)-\(first.end)")
        #expect(paused.segments.count == 2)
        let segmentRequests = resumed
        #expect(segmentRequests.allSatisfy { $0.headers["if-range"] == "\"v1\"" })
        let asked = segmentRequests.compactMap { $0.headers["range"].flatMap(ClosedRangeHeader.init) }
        #expect(ClosedRangeHeader.eachMissingPartIsAskedFromItsStart(paused.segments, asked: asked))
        #expect(ClosedRangeHeader.noneAsksForReceivedBytes(paused.segments, asked: asked))
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
        // The segments were kept: no request starts the file again from byte 0.
        #expect(!server.requests[requestsWhenPaused...].contains { $0.headers["range"]?.hasPrefix("bytes=0-") == true })
        #expect(try TestFiles.sha256(of: folder.appending(path: "signed.bin")) == TestFiles.sha256(data))
    }

    /// Resume's first request stays open for its segment. Opening all connections at once still
    /// sends the other segment's request only after it, on a host that allows one connection.
    @Test func resumingAllAtOnceOnAHostThatAllowsOneConnectionIsNeverRefused() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 43)
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"o1\"")
        var options = RequestOptions()
        options.openExtraConnections = .allAtOnce
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/one.iso", options: options)
        await engine.pause(id)

        // From here on the server allows one reply at a time, and the first segment's rest trickles.
        var limited = file
        limited.maxParallel = 1
        limited.throttle = .init(rangeStart: Self.held, bytesPerSecond: 4 * 1024 * 1024)
        server.serve(limited, at: "/one.iso")
        server.releaseHeldResponses()
        await engine.configuration.hostLimits.updateLimit(for: "127.0.0.1:\(server.port)") { _ in 1 }
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "one.iso")) == TestFiles.sha256(data))
        #expect(server.refusals(at: "/one.iso") == 0)
        #expect(server.peakParallel(at: "/one.iso") == 1)
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
        let requestsWhenPaused = server.requests.count
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "report.pdf")) == TestFiles.sha256(new))
        // Resume's first request carried the old validator and got the new file with 200. That
        // reply was the new version's first segment, so nothing asks for byte 0 again, and every
        // later request carries the new validator.
        let resumed = server.requests[requestsWhenPaused...]
        #expect(resumed.first?.headers["if-range"] == "\"old\"")
        #expect(!resumed.contains { $0.headers["range"]?.hasPrefix("bytes=0-") == true })
        #expect(resumed.dropFirst().allSatisfy { $0.headers["if-range"] == "\"new\"" })
    }

    enum ChangeWhilePaused: CaseIterable, Sendable, CustomTestStringConvertible {
        case rangesStopped
        case shrankBelowTheMissingPart
        case grewWithTheSameValidator
        case rangeRepliesEncoded

        var testDescription: String {
            switch self {
            case .rangesStopped: "the server stopped serving ranges"
            case .shrankBelowTheMissingPart: "the file shrank below the missing part"
            case .grewWithTheSameValidator: "the file grew and kept its validator"
            case .rangeRepliesEncoded: "range replies became encoded"
            }
        }

        func file(was old: Data) -> TestServer.File {
            switch self {
            case .rangesStopped:
                .init(data: TestServer.makeData(size: 3 * 1024 * 1024, seed: 46), supportsRanges: false, eTag: "\"r2\"")
            case .shrankBelowTheMissingPart:
                .init(data: TestServer.makeData(size: 128 * 1024, seed: 47), eTag: "\"r1\"")
            case .grewWithTheSameValidator:
                .init(data: TestServer.makeData(size: 5 * 1024 * 1024, seed: 48), eTag: "\"r1\"")
            case .rangeRepliesEncoded:
                .init(data: old, eTag: "\"r1\"", rangeReplyHeaders: ["Content-Encoding": "gzip"])
            }
        }
    }

    /// Resume's first request can't continue the download, so it starts over with what the server
    /// now serves. A 200 is read as the new file at once. Anything else asks for the whole file
    /// with `bytes=0-`, which falls back to one connection when ranges don't work.
    @Test(arguments: ChangeWhilePaused.allCases)
    func aResumeThatCantContinueStartsOver(_ change: ChangeWhilePaused) async throws {
        let server = try await TestServer()
        let old = TestServer.makeData(size: Self.size, seed: 45)
        let (engine, id, folder) = try await startHeld(
            server, file: .init(data: old, holdAfterBytes: Self.held, eTag: "\"r1\""), at: "/changing.bin"
        )
        await engine.pause(id)
        let now = change.file(was: old)
        server.serve(now, at: "/changing.bin")
        server.releaseHeldResponses()
        let requestsWhenPaused = server.requests.count
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "changing.bin")) == TestFiles.sha256(now.data))
        let resumed = server.requests[requestsWhenPaused...].map { $0.headers["range"] }
        #expect(server.requests[requestsWhenPaused].headers["if-range"] == "\"r1\"")
        switch change {
        case .rangesStopped:
            #expect(resumed.count == 1)
        case .shrankBelowTheMissingPart, .grewWithTheSameValidator:
            #expect(resumed.dropFirst().first == "bytes=0-")
        case .rangeRepliesEncoded:
            #expect(Array(resumed.dropFirst()) == ["bytes=0-", nil])
        }
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
        // A changed file can't be detected, so the download starts again as a new one: its first
        // request asks for the whole file, and it splits again.
        #expect(server.requests[requestsWhenPaused].headers["range"] == "bytes=0-")
        let resumedStarts = Set(server.requests[requestsWhenPaused...].compactMap { request -> Int? in
            guard let range = request.headers["range"] else { return nil }
            return Int(range.dropFirst("bytes=".count).prefix { $0 != "-" })
        })
        #expect(resumedStarts.contains(0))
        #expect(resumedStarts.count >= 2)
    }

    @Test func aFileChangedMidDownloadStartsOverOnce() async throws {
        let server = try await TestServer()
        let old = TestServer.makeData(size: Self.size, seed: 39)
        let new = TestServer.makeData(size: Self.size, seed: 40)
        // The first request sees the old file, and its reply is slow. The second segment's
        // request, sent with If-Range "old", gets the new file with 200.
        server.serve(
            .init(
                data: old, eTag: "\"old\"", changeAfter: .init(afterRequests: 1, data: new, eTag: "\"new\""),
                throttle: .init(rangeStart: 0, bytesPerSecond: 4 * 1024 * 1024)
            ),
            at: "/build.zip"
        )
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
        // The first reply is slow, so a second connection asks with the validator it gave.
        server.serve(
            .init(data: TestServer.makeData(size: Self.size, seed: 41), newETagEveryRequest: true, throttle: .init(rangeStart: 0, bytesPerSecond: 4 * 1024 * 1024)),
            at: "/live.log"
        )
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
        server.serve(.init(data: TestServer.makeData(size: 3 * 1024 * 1024), holdAfterBytes: Self.held, eTag: "\"a\""), at: "/page-file.zip")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 3
        options.referrer = URL(string: "https://example.com/downloads")
        options.userAgent = "DowlioTest/1.0"

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/page-file.zip"), to: folder, options: options)
        try await waitUntil { server.requests.count >= 2 }
        server.releaseHeldResponses()
        _ = try await engine.completedOrFailed(id)

        #expect(server.requests.allSatisfy { $0.headers["referer"] == "https://example.com/downloads" })
        #expect(server.requests.allSatisfy { $0.headers["user-agent"] == "DowlioTest/1.0" })
    }
}
