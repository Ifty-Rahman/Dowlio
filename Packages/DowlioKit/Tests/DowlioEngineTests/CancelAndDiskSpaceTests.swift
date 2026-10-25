import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CancelAndDiskSpaceTests {
    @Test func cancelThrowsTheDownloadAwayCompletely() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024)
        server.serve(.init(data: data, holdAfterBytes: 64 * 1024), at: "/movie.mkv")
        let folder = try TestFiles.makeFolder()

        // One connection, so no request is still on its way to the server when Cancel runs.
        var options = RequestOptions()
        options.connections = 1
        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/movie.mkv"), to: folder, options: options)
        let states = Task {
            var states: [DownloadState] = []
            for await snapshot in await engine.snapshots(of: id) { states.append(snapshot.state) }
            return states
        }
        _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes > 0 }

        await engine.cancel(id)

        #expect(await states.value.last == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        var later: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) { later.append(snapshot) }
        #expect(later.isEmpty)

        // The connection is gone, so releasing the server's response writes nothing, and nothing
        // more is asked for. Another whole download through the same engine and server comes
        // first, so the check follows real requests rather than a fixed wait.
        let requestsWhenCancelled = server.requests.count { $0.path == "/movie.mkv" }
        server.releaseHeldResponses()
        try await engine.runOtherDownload(on: server)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(server.requests.count { $0.path == "/movie.mkv" } == requestsWhenCancelled)
    }

    @Test func theFullSizeIsReservedBeforeTheBytesArrive() async throws {
        let server = try await TestServer()
        let size = 16 * 1024 * 1024
        server.serve(.init(data: TestServer.makeData(size: size), holdAfterBytes: 64 * 1024), at: "/big.iso")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/big.iso"), to: folder)
        _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes > 0 }

        let data = folder.appending(path: "big.iso.dowlio/data")
        let allocated = try data.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(allocated >= size)

        server.releaseHeldResponses()
        #expect(try await engine.completedOrFailed(id).state == .completed)
    }

    @Test func aFileThatCantFitFailsBeforeAnyDataIsRequested() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 16 * 1024 * 1024)), at: "/huge.dmg")
        let volume = try DiskImage(megabytes: 8)
        defer { volume.detach() }

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/huge.dmg"), to: volume.folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .failed(.notEnoughSpace))
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.headers["range"] == "bytes=0-")
    }

    @Test func aReadOnlyFolderFailsAsNotWritable() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024)), at: "/locked.pdf")
        let folder = try TestFiles.makeFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/locked.pdf"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .failed(.destinationNotWritable))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// Without ranges, the probe's reply is the download. A folder that can't hold the partial
    /// file fails the download before that reply is read, and its connection must still close.
    @Test func aProbeReplyTheDownloadNeverReadsIsClosed() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024), supportsRanges: false, holdAfterBytes: 64 * 1024), at: "/stream.bin")
        let folder = try TestFiles.makeFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        // Longer than the suite's time limit, so only closing the connection can end it in time.
        var configuration = EngineConfiguration.fast
        configuration.idleTimeout = .seconds(600)

        let engine = DownloadEngine(configuration: configuration)
        let id = await engine.add(url: server.url(for: "/stream.bin"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .failed(.destinationNotWritable))
        try await waitUntil { server.openConnections(at: "/stream.bin") == 0 }
    }
}

/// A small HFS+ volume, mounted for one test, to run out of space for real.
private struct DiskImage {
    let folder: URL
    private let image: URL

    init(megabytes: Int) throws {
        let base = try TestFiles.makeFolder()
        image = base.appending(path: "volume.dmg")
        folder = base.appending(path: "mount", directoryHint: .isDirectory)
        try Self.hdiutil(["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "DowlioTest", image.path])
        try Self.hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", folder.path])
    }

    func detach() {
        try? Self.hdiutil(["detach", folder.path, "-force"])
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed"])
        }
    }
}
