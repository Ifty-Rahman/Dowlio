import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RetryTests {
    @Test(arguments: [
        (401, DownloadError.needsSignIn),
        (403, DownloadError.forbidden),
        (404, DownloadError.notFound),
        (410, DownloadError.notFound),
    ])
    func refusalsOnTheFirstRequestFailWithoutRetrying(status: Int, error: DownloadError) async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024), failFirst: .init(status: status)), at: "/locked.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/locked.zip"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .failed(error))
        #expect(server.requests.count == 1)
    }

    @Test func otherClientErrorsFailWithoutRetrying() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024), failFirst: .init(status: 400)), at: "/bad.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/bad.zip"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        guard case .failed = finished.state else {
            Issue.record("Expected Failed, got \(finished.state)")
            return
        }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [408, 429, 500, 502, 503])
    func busyServersAreRetriedUntilTheDownloadCompletes(status: Int) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: UInt64(status))
        server.serve(.init(data: data, failFirst: .init(status: status, count: 2)), at: "/busy.iso")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/busy.iso"), to: folder)
        let states = await recordStates(of: id, in: engine)

        #expect(states.last == .completed)
        #expect(states.contains { if case .retrying = $0 { true } else { false } })
        let retryingIndex = try #require(states.lastIndex { if case .retrying = $0 { true } else { false } })
        #expect(states[(retryingIndex + 1)...].contains(.downloading))
        #expect(try TestFiles.sha256(of: folder.appending(path: "busy.iso")) == TestFiles.sha256(data))
    }
}

extension RetryTests {
    @Test func aDroppedConnectionResumesItsSegmentFromTheBytesItHas() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 21)
        let cut = 256 * 1024
        server.serve(.init(data: data, dropFirst: .init(afterBytes: cut, count: 2)), at: "/flaky.zip")
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.connections = 1
        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/flaky.zip"), to: folder, options: options)
        var received: [Int64] = []
        var last: DownloadSnapshot?
        for await snapshot in await engine.snapshots(of: id) {
            received.append(snapshot.receivedBytes)
            last = snapshot
        }

        #expect(last?.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "flaky.zip")) == TestFiles.sha256(data))
        // How many bytes arrive before a dropped connection varies, because URLSession may discard
        // the last ones it buffered. What must hold: progress never goes back, and each new request
        // starts at or after the previous one and runs to the end of the file. An engine that
        // restarted the segment would ask for byte 0 again.
        #expect(received == received.sorted())
        let starts = server.requests.compactMap { $0.headers["range"] }.dropFirst(2).map { range -> Int in
            #expect(range.hasSuffix("-\(data.count - 1)"))
            return Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }) ?? -1
        }
        #expect(starts.count == 2)
        #expect(starts == starts.sorted())
        #expect(starts.allSatisfy { $0 >= 0 && $0 <= 2 * cut })
        #expect(starts.last ?? 0 > 0)
    }

    @Test func fiveFailuresMakeTheDownloadFailedAndRetryContinuesIt() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 22)
        let cut = 128 * 1024
        server.serve(.init(data: data, eTag: "\"st1\"", dropFirst: .init(afterBytes: cut, count: 5)), at: "/stubborn.iso")
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.connections = 1
        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/stubborn.iso"), to: folder, options: options)
        let failed = try await engine.completedOrFailed(id)

        #expect(failed.state == .failed(.tooManyRetries))
        #expect(failed.activeConnections == 0)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "stubborn.iso.dowlio").path))
        // Every connection stopped: no request arrives after the download failed, and it stays
        // Failed with the same bytes. Another whole download through the same engine and server
        // comes first, so the check follows real requests rather than a fixed wait.
        let requestsWhenFailed = server.requests.count { $0.path == "/stubborn.iso" }
        try await engine.runOtherDownload(on: server)
        #expect(server.requests.count { $0.path == "/stubborn.iso" } == requestsWhenFailed)
        let stillFailed = try await engine.firstSnapshot(of: id) { _ in true }
        #expect(stillFailed.state == .failed(.tooManyRetries))
        #expect(stillFailed.receivedBytes == failed.receivedBytes)

        await engine.retry(id)
        let finished = try await engine.firstSnapshot(of: id) { $0.state == .completed }

        #expect(finished.receivedBytes == Int64(data.count))
        #expect(try TestFiles.sha256(of: folder.appending(path: "stubborn.iso")) == TestFiles.sha256(data))
        // Retry probed the link again, then asked for only the bytes the download didn't have
        // when it failed.
        let afterFailure = server.requests.filter { $0.path == "/stubborn.iso" }.dropFirst(requestsWhenFailed)
        #expect(failed.receivedBytes > 0)
        #expect(afterFailure.map { $0.headers["range"] } == ["bytes=0-0", "bytes=\(failed.receivedBytes)-\(data.count - 1)"])
    }
}

extension RetryTests {
    static let size = 4 * 1024 * 1024
    static let held = 256 * 1024

    @Test func retryAfterLinkExpiredAsksForTheOriginalLinkAgainAndKeepsTheBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 27)
        server.redirect("/once", to: "/signed.bin")
        let file = TestServer.File(data: data, holdAfterBytes: Self.held, eTag: "\"e1\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/signed.bin", start: "/once")
        await engine.pause(id)
        server.remove("/once")
        server.remove("/signed.bin")
        server.releaseHeldResponses()
        await engine.resume(id)
        #expect(try await engine.completedOrFailed(id).state == .failed(.linkExpired))

        // The original link works again and leads to a new signed link for the same file.
        server.serve(file, at: "/signed-2.bin")
        server.redirect("/once", to: "/signed-2.bin")
        let requestsWhenFailed = server.requests.count
        await engine.retry(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "signed.bin")) == TestFiles.sha256(data))
        let afterFailure = server.requests[requestsWhenFailed...]
        #expect(afterFailure.first?.path == "/once")
        #expect(!afterFailure.contains { $0.headers["range"]?.hasPrefix("bytes=0-") == true && $0.headers["range"] != "bytes=0-0" })
    }

    @Test func retryAfterTheFileChangedStartsOver() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: Self.size, seed: 28), newETagEveryRequest: true), at: "/live.log")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2
        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/live.log"), to: folder, options: options)
        #expect(try await engine.completedOrFailed(id).state == .failed(.serverChangedFile))

        let settled = TestServer.makeData(size: Self.size, seed: 29)
        server.serve(.init(data: settled, eTag: "\"settled\""), at: "/live.log")
        let requestsWhenFailed = server.requests.count
        await engine.retry(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "live.log")) == TestFiles.sha256(settled))
        // Retry probed first, then asked for the new version from byte 0 and never with the
        // validator of the version that kept changing.
        let afterFailure = server.requests[requestsWhenFailed...]
        #expect(afterFailure.first?.headers["range"] == "bytes=0-0")
        let segmentRequests = afterFailure.dropFirst()
        #expect(segmentRequests.contains { $0.headers["range"] == "bytes=0-\(Self.size - 1)" })
        #expect(segmentRequests.allSatisfy { $0.headers["if-range"] == "\"settled\"" })
    }
}

extension RetryTests {
    /// With the clock and the jitter fixed, the next try's time shows each wait exactly: it doubles
    /// from the first wait, varies by the jitter, and never exceeds the maximum.
    @Test(arguments: [
        (0.8, [8, 16, 30, 30]),
        (1.2, [12, 24, 30, 30]),
    ])
    func waitsDoubleCarryJitterAndAreCapped(jitter: Double, expectedMilliseconds: [Int]) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024, seed: 23)
        server.serve(.init(data: data, dropFirst: .init(afterBytes: 1024, count: 4)), at: "/steady.bin")
        let folder = try TestFiles.makeFolder()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = EngineConfiguration.fast
        configuration.retry.firstDelay = .milliseconds(10)
        configuration.retry.maximumDelay = .milliseconds(30)
        configuration.now = { now }
        configuration.random = { range in jitter < 1 ? range.lowerBound : range.upperBound }
        var options = RequestOptions()
        options.connections = 1
        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/steady.bin"), to: folder, options: options)
        let states = await recordStates(of: id, in: engine)

        let waits = states.compactMap { state -> Int? in
            guard case .retrying(_, let nextTry) = state else { return nil }
            return Int((nextTry.timeIntervalSince(now) * 1000).rounded())
        }
        let attempts = states.compactMap { state -> Int? in
            guard case .retrying(let attempt, _) = state else { return nil }
            return attempt
        }
        #expect(states.last == .completed)
        #expect(attempts == [1, 2, 3, 4])
        #expect(waits == expectedMilliseconds)
    }
}

extension RetryTests {
    /// A server's `Retry-After` replaces the computed wait, as seconds or as a date, and is capped.
    @Test(arguments: [
        ("1", 1000),
        ("Fri, 15 Jan 2027 08:00:01 GMT", 1000),
        ("3600", 200),
    ])
    func retryAfterSetsTheWaitUpToTheCap(retryAfter: String, expectedMilliseconds: Int) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 512 * 1024, seed: 24)
        let busy = TestServer.StatusFault(status: 503, count: 1, headers: ["Retry-After": retryAfter])
        server.serve(.init(data: data, failFirst: busy), at: "/later.zip")
        let folder = try TestFiles.makeFolder()

        // 08:00:00 GMT on the date the second argument names.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var configuration = EngineConfiguration.fast
        // Only the 3600-second case reaches the cap.
        configuration.retry.maximumRetryAfter = expectedMilliseconds == 200 ? .milliseconds(200) : .seconds(5)
        configuration.now = { now }
        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/later.zip"), to: folder)
        let states = await recordStates(of: id, in: engine)

        let waits = states.compactMap { state -> Int? in
            guard case .retrying(_, let nextTry) = state else { return nil }
            return Int((nextTry.timeIntervalSince(now) * 1000).rounded())
        }
        #expect(waits == [expectedMilliseconds])
        #expect(states.last == .completed)
    }
}

extension RetryTests {
    @Test func aSilentConnectionTimesOutAndIsRetried() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024, seed: 25)
        let cut = 64 * 1024
        server.serve(.init(data: data, stallFirst: .init(afterBytes: cut, count: 1)), at: "/quiet.bin")
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.connections = 1
        var configuration = EngineConfiguration.fast
        configuration.idleTimeout = .seconds(2)
        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/quiet.bin"), to: folder, options: options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "quiet.bin")) == TestFiles.sha256(data))
        #expect(server.requests.last?.headers["range"] == "bytes=\(cut)-\(data.count - 1)")
    }
}

extension RetryTests {
    /// A server without range support can't resume, so a retry starts the file over.
    @Test func aDropFromAServerThatCantResumeStartsTheFileOver() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024, seed: 26)
        server.serve(.init(data: data, supportsRanges: false, dropFirst: .init(afterBytes: 300 * 1024, count: 1)), at: "/plain.tar")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/plain.tar"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.receivedBytes == Int64(data.count))
        #expect(try TestFiles.sha256(of: folder.appending(path: "plain.tar")) == TestFiles.sha256(data))
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.headers["range"] == nil)
    }
}

/// Every state the download goes through, until Completed or Failed.
func recordStates(of id: DownloadID, in engine: DownloadEngine) async -> [DownloadState] {
    var states: [DownloadState] = []
    for await snapshot in await engine.snapshots(of: id) {
        if states.last != snapshot.state { states.append(snapshot.state) }
        if case .failed = snapshot.state { break }
    }
    return states
}

extension RetryTests {
    /// The retry setting is per download, so a change applies to downloads added or restored
    /// afterwards.
    @Test func aDownloadGivesUpAfterItsOwnNumberOfFailures() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 27)
        server.serve(.init(data: data, eTag: "\"own1\"", dropFirst: .init(afterBytes: 128 * 1024, count: 5)), at: "/flaky.iso")
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.connections = 1
        options.maximumFailures = 2
        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/flaky.iso"), to: folder, options: options)
        let failed = try await engine.completedOrFailed(id)

        #expect(failed.state == .failed(.tooManyRetries))
        #expect(server.requests.count { $0.path == "/flaky.iso" && $0.headers["range"] != "bytes=0-0" } == 2)

        let restoring = DownloadEngine(configuration: .fast)
        let restored = try await restoring.restore(partialFile: TestFiles.partialFile(in: folder), maximumFailures: 3)
        await restoring.resume(restored)
        let failedAgain = try await restoring.completedOrFailed(restored)

        #expect(failedAgain.state == .failed(.tooManyRetries))
        #expect(server.requests.count { $0.path == "/flaky.iso" && $0.headers["range"] != "bytes=0-0" } == 5)
    }
}
