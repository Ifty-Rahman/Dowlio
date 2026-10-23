import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreTests {
    static let size = 4 * 1024 * 1024
    static let held = 256 * 1024

    /// Starts a two-segment download whose replies hold after `held` bytes, and waits until both
    /// segments have their held bytes.
    private func startHeld(
        _ server: TestServer,
        data: Data,
        at path: String
    ) async throws -> (DownloadEngine, DownloadID, URL) {
        server.serve(.init(data: data, holdAfterBytes: Self.held, eTag: "\"v1\""), at: path)
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2
        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: path), to: folder, options: options)
        _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes == Int64(2 * Self.held) }
        return (engine, id, folder)
    }

    /// The one partial file in `folder`.
    private func partialFile(in folder: URL) throws -> URL {
        let packages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dowlio" }
        return try #require(packages.count == 1 ? packages.first : nil)
    }

    @Test func anUnknownPartialFileIsRestoredAsPausedAndResumesWithOnlyTheMissingBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 41)
        let (engine, id, folder) = try await startHeld(server, data: data, at: "/backup.tar")
        await engine.pause(id)
        let package = try partialFile(in: folder)

        let fresh = DownloadEngine(configuration: .fastWithHolds)
        let restored = try await fresh.restore(partialFile: package)
        let snapshot = try await fresh.firstSnapshot(of: restored) { _ in true }

        #expect(snapshot.state == .paused)
        #expect(snapshot.fileName == "backup.tar")
        #expect(snapshot.destinationFolder.standardizedFileURL == folder.standardizedFileURL)
        #expect(snapshot.totalBytes == Int64(data.count))
        #expect(snapshot.receivedBytes == Int64(2 * Self.held))
        #expect(snapshot.canResume)

        server.releaseHeldResponses()
        let requestsBeforeResume = server.requests.count
        await fresh.resume(restored)
        let finished = try await fresh.finished(restored)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "backup.tar")) == TestFiles.sha256(data))
        let half = Self.size / 2
        let segmentRanges = Set(server.requests[requestsBeforeResume...]
            .compactMap { $0.headers["range"] }
            .filter { $0 != "bytes=0-0" })
        #expect(segmentRanges == [
            "bytes=\(Self.held)-\(half - 1)",
            "bytes=\(half + Self.held)-\(Self.size - 1)",
        ])
    }

    @Test func aDownloadSurvivesACrashFromWhateverTheLastSaveWrote() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 43)
        let (engine, id, folder) = try await startHeld(server, data: data, at: "/crash.dmg")
        let package = try partialFile(in: folder)

        // Wait for a periodic save that records bytes, then keep the partial file exactly as it is
        // on disk, as a crash would leave it. No pause runs, so nothing saves on the way out.
        let manifestURL = package.appending(path: "manifest.json")
        try await waitUntil {
            guard let saved = try? JSONDecoder().decode(PartialFileManifest.self, from: Data(contentsOf: manifestURL)) else { return false }
            return saved.segments.contains { $0.received > 0 }
        }
        let crashImage = try TestFiles.makeFolder().appending(path: package.lastPathComponent)
        try FileManager.default.copyItem(at: package, to: crashImage)
        await engine.cancel(id)
        try FileManager.default.moveItem(at: crashImage, to: package)
        let saved = try JSONDecoder().decode(PartialFileManifest.self, from: Data(contentsOf: manifestURL))

        let fresh = DownloadEngine(configuration: .fastWithHolds)
        let restored = try await fresh.restore(partialFile: package)
        let snapshot = try await fresh.firstSnapshot(of: restored) { _ in true }
        #expect(snapshot.receivedBytes == saved.segments.reduce(0) { $0 + $1.received })

        server.releaseHeldResponses()
        await fresh.resume(restored)
        let finished = try await fresh.finished(restored)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "crash.dmg")) == TestFiles.sha256(data))
    }

    @Test func aDownloadWhosePartialFileWasDeletedStartsOver() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 44)
        let (engine, id, folder) = try await startHeld(server, data: data, at: "/gone.pkg")
        await engine.pause(id)
        try FileManager.default.removeItem(at: try partialFile(in: folder))

        server.releaseHeldResponses()
        let requestsBeforeResume = server.requests.count
        await engine.resume(id)
        var states: [DownloadState] = []
        var last: DownloadSnapshot?
        for await snapshot in await engine.snapshots(of: id) {
            states.append(snapshot.state)
            last = snapshot
        }

        #expect(last?.state == .completed)
        #expect(!states.contains { if case .failed = $0 { true } else { false } })
        #expect(try TestFiles.sha256(of: folder.appending(path: "gone.pkg")) == TestFiles.sha256(data))
        // It started over: the first segment is fetched from byte 0 again.
        let ranges = server.requests[requestsBeforeResume...].compactMap { $0.headers["range"] }
        #expect(ranges.contains("bytes=0-\(Self.size / 2 - 1)"))
    }

    @Test func aPartialFileTheEngineAlreadyHasReturnsThatDownload() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 42)
        let (engine, id, folder) = try await startHeld(server, data: data, at: "/known.iso")

        let restored = try await engine.restore(partialFile: try partialFile(in: folder))

        #expect(restored == id)
        // The running download carries on. It isn't replaced by a paused copy.
        let afterRestore = try await engine.firstSnapshot(of: id) { _ in true }
        #expect(afterRestore.state == .downloading)
        server.releaseHeldResponses()
        let finished = try await engine.finished(id)
        #expect(finished.state == .completed)
    }

    @Test func aPartialFileWithoutAReadableManifestIsLeftAlone() async throws {
        let folder = try TestFiles.makeFolder()
        let package = folder.appending(path: "broken.zip.dowlio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let bytes = Data("the bytes the user already has".utf8)
        try bytes.write(to: package.appending(path: "data"))
        try Data("not a manifest".utf8).write(to: package.appending(path: "manifest.json"))

        let engine = DownloadEngine()
        await #expect(throws: RestoreError.unreadableManifest) {
            try await engine.restore(partialFile: package)
        }
        #expect(try Data(contentsOf: package.appending(path: "data")) == bytes)
        #expect(try Data(contentsOf: package.appending(path: "manifest.json")) == Data("not a manifest".utf8))
    }
}
