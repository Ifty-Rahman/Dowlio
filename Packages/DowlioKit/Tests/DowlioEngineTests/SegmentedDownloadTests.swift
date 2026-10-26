import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SegmentedDownloadTests {
    @Test func aLargeFileDownloadsOverEightConnectionsByDefault() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 21)
        server.serve(.init(data: data, throttle: .init(rangeStart: 0, bytesPerSecond: 4 * 1024 * 1024)), at: "/big.iso")
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.allowsWorkStealing = false

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/big.iso"), to: folder, options: options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "big.iso")) == TestFiles.sha256(data))
        let segmentRanges = server.requests.compactMap { $0.headers["range"] }
        #expect(segmentRanges.count == 8)
        #expect(segmentRanges.first == "bytes=0-")
        #expect(finished.segments.count == 8)
    }

    @Test func theConnectionSettingDecidesHowManyConnectionsOpen() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 12 * 1024 * 1024, seed: 22)
        server.serve(.init(data: data), at: "/three.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 3

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/three.bin"), to: folder, options: options)
        var mostConnections = 0
        var last: DownloadSnapshot?
        for await snapshot in await engine.snapshots(of: id) {
            mostConnections = max(mostConnections, snapshot.activeConnections)
            last = snapshot
        }

        #expect(last?.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "three.bin")) == TestFiles.sha256(data))
        #expect(server.requests.first?.headers["range"] == "bytes=0-")
        #expect(mostConnections <= 3)
        #expect(server.peakParallel(at: "/three.bin") <= 3)
    }

    @Test func extraConnectionsWaitUntilTheFirstOneReceivesData() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 24)
        server.serve(.init(data: data, holdAfterBytes: 0), at: "/ramp.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/ramp.bin"), to: folder)
        let (log, following) = await SnapshotLog.follow(id, in: engine)
        try await waitUntil { server.requests.count >= 2 }
        try await EngineEvents.waitForManifestSaves(2, in: folder.appending(path: "ramp.bin.dowlio"))
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=0-", "bytes=4194560-8388607"])
        #expect(log.snapshots.allSatisfy { $0.activeConnections <= 2 })

        server.releaseHeldResponses()
        await following.value
        #expect(log.snapshots.last?.state == .completed)
        #expect(server.requests.count >= 8)
        #expect(server.requests.dropFirst().allSatisfy { $0.headers["range"]?.hasPrefix("bytes=0-") == false })
        // Every snapshot from before the first data shows at most the first connection.
        #expect(log.snapshots.filter { $0.receivedBytes == 0 }.allSatisfy { $0.activeConnections <= 1 })
    }

    @Test func allAtOnceOpensEveryConnectionWithoutWaiting() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 25)
        server.serve(.init(data: data, holdAfterBytes: 0), at: "/burst.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.openExtraConnections = .allAtOnce

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/burst.bin"), to: folder, options: options)
        try await waitUntil { server.requests.count == 8 }

        server.releaseHeldResponses()
        let finished = try await engine.completedOrFailed(id)
        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "burst.bin")) == TestFiles.sha256(data))
    }

    @Test func snapshotsShowEachSegmentsProgress() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 26)
        let held = 512 * 1024
        server.serve(.init(data: data, holdAfterBytes: held), at: "/bar.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/bar.bin"), to: folder)
        let midway = try await engine.firstSnapshot(of: id) {
            $0.receivedBytes == Int64(8 * held) && $0.bytesPerSecond > 0
        }

        #expect(midway.segments.count == 8)
        #expect(midway.segments.first?.start == 0 && midway.segments.last?.end == 8_388_607)
        #expect(zip(midway.segments, midway.segments.dropFirst()).allSatisfy { $0.end + 1 == $1.start })
        #expect(midway.segments.allSatisfy { $0.receivedBytes == Int64(held) && $0.isActive })
        #expect(midway.activeConnections == 8)
        #expect(midway.timeRemaining != nil)

        server.releaseHeldResponses()
        let finished = try await engine.completedOrFailed(id)
        #expect(finished.state == .completed)
        #expect(finished.segments.allSatisfy { $0.receivedBytes == $0.end - $0.start + 1 && !$0.isActive })
        #expect(finished.activeConnections == 0)
    }

    struct ValidatorCase: Sendable, CustomTestStringConvertible {
        let eTag: String?
        let lastModified: String?
        let expectedIfRange: String?
        let testDescription: String
    }

    static let validatorCases: [ValidatorCase] = [
        ValidatorCase(eTag: "\"v1-abc\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
                      expectedIfRange: "\"v1-abc\"", testDescription: "a strong ETag wins"),
        ValidatorCase(eTag: "W/\"weak\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
                      expectedIfRange: "Wed, 21 Oct 2026 07:28:00 GMT", testDescription: "a weak ETag falls back to Last-Modified"),
        ValidatorCase(eTag: nil, lastModified: nil, expectedIfRange: nil, testDescription: "no validator sends no If-Range"),
    ]

    @Test(arguments: validatorCases)
    func everySegmentRequestCarriesTheValidator(_ testCase: ValidatorCase) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 23)
        server.serve(.init(data: data, eTag: testCase.eTag, lastModified: testCase.lastModified, throttle: .init(rangeStart: 0, bytesPerSecond: 4 * 1024 * 1024)), at: "/tagged.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/tagged.zip"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        let segmentRequests = Array(server.requests.dropFirst())
        #expect(segmentRequests.count >= 2)
        #expect(segmentRequests.allSatisfy { $0.headers["if-range"] == testCase.expectedIfRange })
        #expect(server.requests.first?.headers["if-range"] == nil)
    }
}
