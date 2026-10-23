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

    @Test func theDisplayHostIsTheOriginalLinksHostInLowercase() async throws {
        let folder = try TestFiles.makeFolder()
        let engine = DownloadEngine(configuration: .fast)
        // Nothing listens on port 1, so this only checks the snapshot before the download fails.
        let id = await engine.add(url: URL(string: "http://LocalHost:1/Report.pdf")!, to: folder)

        let first = try await engine.firstSnapshot(of: id) { _ in true }

        #expect(first.displayHost == "localhost")
    }

    @Test func theDisplayHostStaysTheOriginalLinksHostThroughARedirect() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024)), at: "/file.txt")
        server.redirect("/go", to: "http://localhost:\(server.port)/file.txt")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/go"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.displayHost == "127.0.0.1")
    }

    @Test func aRestoredDownloadHasTheDisplayHostOfItsOriginalLink() async throws {
        let folder = try TestFiles.makeFolder()
        let package = folder.appending(path: "a.zip.dowlio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(count: 1024).write(to: package.appending(path: "data"))
        let manifest = PartialFileManifest(
            formatVersion: PartialFileManifest.currentFormatVersion,
            downloadID: UUID().uuidString,
            originalURL: URL(string: "https://Files.Example.com/a.zip")!,
            finalURL: URL(string: "https://cdn.example.net/a.zip")!,
            validator: "\"a1\"",
            totalBytes: 2048,
            fileName: "a.zip",
            connections: 8,
            segments: [.init(start: 0, end: 2047, received: 1024)],
            layout: .ranges
        )
        try JSONEncoder().encode(manifest).write(to: package.appending(path: "manifest.json"))

        let engine = DownloadEngine()
        let restored = try await engine.restore(partialFile: package)
        let snapshot = try await engine.firstSnapshot(of: restored) { _ in true }

        #expect(snapshot.displayHost == "files.example.com")
    }
}
