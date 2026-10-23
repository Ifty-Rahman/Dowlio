import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// The stream of all downloads' snapshots, and snapshot fields that don't belong to one ticket.
@Suite(.timeLimit(.minutes(1)))
struct SnapshotTests {
    @Test func theStreamOfAllDownloadsStartsWithEachDownloadAndFollowsEveryChange() async throws {
        let server = try await TestServer()
        let firstData = TestServer.makeData(size: 2 * 1024 * 1024, seed: 61)
        server.serve(.init(data: firstData, holdAfterBytes: 64 * 1024), at: "/first.bin")
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 62)), at: "/second.txt")
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 63)), at: "/third.txt")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let first = await engine.add(url: server.url(for: "/first.bin"), to: folder)
        _ = try await engine.firstSnapshot(of: first) { $0.receivedBytes > 0 }

        var all = await engine.allSnapshots().makeAsyncIterator()
        #expect(await all.next()?.id == first)

        // A second download shows up from its first snapshot and runs to the end while the
        // first one is held.
        let second = await engine.add(url: server.url(for: "/second.txt"), to: folder)
        var secondStates: [DownloadState] = []
        while let snapshot = await all.next() {
            guard snapshot.id == second else { continue }
            secondStates.append(snapshot.state)
            if snapshot.state == .completed { break }
        }
        #expect(secondStates.first == .probing)
        #expect(secondStates.last == .completed)

        server.releaseHeldResponses()
        var firstCompleted: DownloadSnapshot?
        while let snapshot = await all.next() {
            if snapshot.id == first, snapshot.state == .completed {
                firstCompleted = snapshot
                break
            }
        }
        #expect(firstCompleted?.receivedBytes == Int64(firstData.count))

        // The stream doesn't end when every download has finished.
        let third = await engine.add(url: server.url(for: "/third.txt"), to: folder)
        #expect(await all.next()?.id == third)
    }
}
