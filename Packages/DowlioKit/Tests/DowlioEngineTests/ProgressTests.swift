import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Story 26: progress goes out at most about 4 times a second, and not at all while nothing changes.
@Suite(.timeLimit(.minutes(1)))
struct ProgressTests {
    @Test func noSnapshotGoesOutWhileNothingChanges() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 61)
        // Every body is held at its first byte, so the first connection opens and then receives
        // nothing, and the other connections wait for its first data.
        server.serve(.init(data: data, holdAfterBytes: 0), at: "/still.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/still.bin"), to: folder)
        let (log, following) = await SnapshotLog.follow(id, in: engine)
        // A progress tick has seen the open connection.
        try await waitUntil { log.snapshots.contains { $0.activeConnections == 1 } }
        let countAfterTick = log.snapshots.count

        // Two manifest saves mean at least 4 more progress ticks found the same reading.
        try await EngineEvents.waitForManifestSaves(2, in: folder.appending(path: "still.bin.dowlio"))
        #expect(log.snapshots.count == countAfterTick)

        server.releaseHeldResponses()
        await following.value
        let snapshots = log.snapshots
        #expect(snapshots.last?.state == .completed)
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0 != $1 })
        #expect(try TestFiles.sha256(of: folder.appending(path: "still.bin")) == TestFiles.sha256(data))
    }

    /// Story 22: while bytes arrive, the snapshots carry the speed and the time left, and the time
    /// left goes down as the download goes on.
    @Test func snapshotsShowTheSpeedAndTheTimeLeft() async throws {
        let server = try await TestServer()
        let size = 2 * 1024 * 1024
        let data = TestServer.makeData(size: size, seed: 63)
        server.serve(.init(data: data, throttle: .init(rangeStart: 0, bytesPerSecond: 1024 * 1024)), at: "/timed.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 1

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/timed.bin"), to: folder, options: options)
        var snapshots: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) { snapshots.append(snapshot) }

        #expect(snapshots.last?.state == .completed)
        let downloading = snapshots.filter { $0.state == .downloading }
        #expect(downloading.contains { $0.bytesPerSecond > 0 })
        #expect(downloading.filter { $0.bytesPerSecond > 0 }.allSatisfy { $0.timeRemaining != nil && $0.totalBytes == Int64(size) })
        let timesLeft = downloading.compactMap(\.timeRemaining)
        #expect(timesLeft.count >= 2)
        #expect(try #require(timesLeft.last) < (try #require(timesLeft.first)))
        #expect(snapshots.last?.bytesPerSecond == 0)
        #expect(snapshots.last?.timeRemaining == nil)
    }

    @Test func aSteadyDownloadGetsAtMostFourSnapshotsASecond() async throws {
        let server = try await TestServer()
        let size = 2 * 1024 * 1024
        let data = TestServer.makeData(size: size, seed: 62)
        // One connection at 1 MiB a second: about 2 seconds, with new bytes between any two ticks.
        server.serve(.init(data: data, throttle: .init(rangeStart: 0, bytesPerSecond: 1024 * 1024)), at: "/steady.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 1

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/steady.bin"), to: folder, options: options)
        var arrivals: [ContinuousClock.Instant] = []
        var snapshots: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) {
            arrivals.append(.now)
            snapshots.append(snapshot)
        }

        #expect(snapshots.last?.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "steady.bin")) == TestFiles.sha256(data))
        // The bound comes from how long this download took: one snapshot per 250 ms tick, plus a
        // fixed allowance for the state changes (probing, downloading, finalizing, completed and
        // the probe's findings) and for the tick that started before the first snapshot.
        let first = try #require(arrivals.first)
        let last = try #require(arrivals.last)
        let ticks = Int(((last - first) / .milliseconds(250)).rounded(.up))
        #expect(snapshots.count <= ticks + 8)
        // Progress still went out while the bytes arrived.
        let midway = Set(snapshots.map(\.receivedBytes).filter { $0 > 0 && $0 < Int64(size) })
        #expect(midway.count >= 2)
    }
}
