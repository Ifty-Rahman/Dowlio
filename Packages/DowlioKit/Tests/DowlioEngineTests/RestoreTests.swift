import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RestoreTests {
    static let size = 4 * 1024 * 1024
    static let held = 256 * 1024

    private static func heldFile(_ data: Data) -> TestServer.File {
        .init(data: data, holdAfterBytes: held, eTag: "\"v1\"")
    }

    @Test func anUnknownPartialFileIsRestoredAsPausedAndResumesWithOnlyTheMissingBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 41)
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/backup.tar")
        await engine.pause(id)
        let package = try TestFiles.partialFile(in: folder)

        let fresh = DownloadEngine(configuration: .fast)
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
        let finished = try await fresh.completedOrFailed(restored)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "backup.tar")) == TestFiles.sha256(data))
        let segmentRanges = Set(server.requests[requestsBeforeResume...]
            .compactMap { $0.headers["range"] }
            .filter { $0 != "bytes=0-0" })
        // A new connection may split a segment before its own request goes out, so each missing
        // part is asked for from its first missing byte, up to its end or less.
        let asked = segmentRanges.compactMap(ClosedRangeHeader.init)
        #expect(snapshot.segments.count == 2)
        #expect(ClosedRangeHeader.eachMissingPartIsAskedFromItsStart(snapshot.segments, asked: asked))
        #expect(ClosedRangeHeader.noneAsksForReceivedBytes(snapshot.segments, asked: asked))
        #expect(!segmentRanges.contains { $0.hasPrefix("bytes=0-") })
    }

    @Test func aDownloadSurvivesACrashFromWhateverTheLastSaveWrote() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 43)
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/crash.dmg")
        let package = try TestFiles.partialFile(in: folder)

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

        let fresh = DownloadEngine(configuration: .fast)
        let restored = try await fresh.restore(partialFile: package)
        let snapshot = try await fresh.firstSnapshot(of: restored) { _ in true }
        #expect(snapshot.receivedBytes == saved.segments.reduce(0) { $0 + $1.received })

        server.releaseHeldResponses()
        await fresh.resume(restored)
        let finished = try await fresh.completedOrFailed(restored)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "crash.dmg")) == TestFiles.sha256(data))
    }

    @Test func aRestoredDownloadUsesTheHostsLearnedLimit() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 45)
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/limited.iso")
        await engine.pause(id)
        let package = try TestFiles.partialFile(in: folder)
        // From here on the server allows one reply at a time. The replies held before the pause
        // aren't counted. The first segment's rest trickles, so a second connection opened
        // beside it would be refused.
        var limited = Self.heldFile(data)
        limited.maxParallel = 1
        limited.throttle = .init(rangeStart: Self.held, bytesPerSecond: 4 * 1024 * 1024)
        server.serve(limited, at: "/limited.iso")
        server.releaseHeldResponses()

        let limits = InMemoryHostLimitStore()
        limits.updateLimit(for: "127.0.0.1:\(server.port)") { _ in 1 }
        var configuration = EngineConfiguration.fast
        configuration.hostLimits = limits
        let fresh = DownloadEngine(configuration: configuration)
        let restored = try await fresh.restore(partialFile: package)
        await fresh.resume(restored)
        let finished = try await fresh.completedOrFailed(restored)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "limited.iso")) == TestFiles.sha256(data))
        #expect(server.refusals(at: "/limited.iso") == 0)
        #expect(server.peakParallel(at: "/limited.iso") == 1)
    }

    @Test func aDownloadWhosePartialFileWasDeletedStartsOver() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 44)
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/gone.pkg")
        await engine.pause(id)
        try FileManager.default.removeItem(at: try TestFiles.partialFile(in: folder))

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
        // It started over as a new download: its first request asks for the whole file again.
        let ranges = server.requests[requestsBeforeResume...].compactMap { $0.headers["range"] }
        #expect(ranges.first == "bytes=0-")
    }

    @Test func aPartialFileTheEngineAlreadyHasReturnsThatDownload() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 42)
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/known.iso")

        let restored = try await engine.restore(partialFile: try TestFiles.partialFile(in: folder))

        #expect(restored == id)
        // The running download carries on. It isn't replaced by a paused copy.
        let afterRestore = try await engine.firstSnapshot(of: id) { _ in true }
        #expect(afterRestore.state == .downloading)
        server.releaseHeldResponses()
        let finished = try await engine.completedOrFailed(id)
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

/// A partial file is data on disk that anyone could have edited, so restoring one checks it.
extension RestoreTests {
    private static func manifest(
        fileName: String = "a.bin",
        totalBytes: Int64? = 2048,
        connections: Int = 8,
        segments: [PartialFileManifest.Segment] = [.init(start: 0, end: 2047, received: 1024)]
    ) -> PartialFileManifest {
        PartialFileManifest(
            formatVersion: PartialFileManifest.currentFormatVersion,
            downloadID: UUID().uuidString,
            originalURL: URL(string: "https://files.example.com/a.bin")!,
            finalURL: URL(string: "https://files.example.com/a.bin")!,
            validator: "\"a1\"",
            totalBytes: totalBytes,
            fileName: fileName,
            connections: connections,
            segments: segments,
            layout: .ranges
        )
    }

    private static func writePackage(_ manifest: PartialFileManifest, in folder: URL) throws -> URL {
        let package = folder.appending(path: "a.bin.dowlio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(count: 1024).write(to: package.appending(path: "data"))
        try JSONEncoder().encode(manifest).write(to: package.appending(path: "manifest.json"))
        return package
    }

    @Test(arguments: [
        ("../../escape.bin", "escape.bin"),
        ("/etc/passwd", "etcpasswd"),
        (".hidden", "hidden"),
        ("", "download"),
    ])
    func aRestoredFileNameIsCleanedLikeANewOne(saved: String, expected: String) async throws {
        let package = try Self.writePackage(Self.manifest(fileName: saved), in: try TestFiles.makeFolder())

        let engine = DownloadEngine()
        let restored = try await engine.restore(partialFile: package)
        let snapshot = try await engine.firstSnapshot(of: restored) { _ in true }

        #expect(snapshot.fileName == expected)
    }

    struct BrokenSegments: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let totalBytes: Int64?
        let segments: [PartialFileManifest.Segment]
    }

    static let brokenSegments: [BrokenSegments] = [
        .init(testDescription: "past the end", totalBytes: 2048, segments: [.init(start: 0, end: 4095, received: 0)]),
        .init(testDescription: "overlapping", totalBytes: 2048, segments: [
            .init(start: 0, end: 1023, received: 0), .init(start: 1000, end: 2047, received: 0),
        ]),
        .init(testDescription: "out of order", totalBytes: 2048, segments: [
            .init(start: 1024, end: 2047, received: 0), .init(start: 0, end: 1023, received: 0),
        ]),
        .init(testDescription: "more received than the length", totalBytes: 2048, segments: [.init(start: 0, end: 2047, received: 4096)]),
        .init(testDescription: "negative received", totalBytes: 2048, segments: [.init(start: 0, end: 2047, received: -1)]),
        .init(testDescription: "ending before it starts", totalBytes: 2048, segments: [.init(start: 100, end: 50, received: 0)]),
        .init(testDescription: "starting before the file", totalBytes: 2048, segments: [.init(start: -10, end: 2047, received: 0)]),
        .init(testDescription: "segments without a size", totalBytes: nil, segments: [.init(start: 0, end: 1023, received: 0)]),
    ]

    @Test(arguments: brokenSegments)
    func aManifestWhoseSegmentsDontFitTheFileIsRefusedAndLeftAlone(_ broken: BrokenSegments) async throws {
        let package = try Self.writePackage(
            Self.manifest(totalBytes: broken.totalBytes, segments: broken.segments), in: try TestFiles.makeFolder()
        )
        let manifestBytes = try Data(contentsOf: package.appending(path: "manifest.json"))

        let engine = DownloadEngine()
        await #expect(throws: RestoreError.invalidManifest) {
            try await engine.restore(partialFile: package)
        }
        #expect(try Data(contentsOf: package.appending(path: "manifest.json")) == manifestBytes)
        #expect(try Data(contentsOf: package.appending(path: "data")) == Data(count: 1024))
    }

    @Test func aRestoredConnectionSettingIsClampedTo16() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 46)
        // Replies hold early enough that none of the 16 resumed connections can finish its part.
        let early = 64 * 1024
        let file = TestServer.File(data: data, holdAfterBytes: early, eTag: "\"v1\"")
        let (engine, id, folder) = try await startHeld(server, file: file, at: "/many.bin")
        await engine.pause(id)
        let package = try TestFiles.partialFile(in: folder)
        let manifestURL = package.appending(path: "manifest.json")
        var saved = try JSONDecoder().decode(PartialFileManifest.self, from: Data(contentsOf: manifestURL))
        saved.connections = 99
        try JSONEncoder().encode(saved).write(to: manifestURL)

        let fresh = DownloadEngine(configuration: .fast)
        let restored = try await fresh.restore(partialFile: package)
        await fresh.resume(restored)
        // A resumed connection got bytes, so the resume is past its probe.
        _ = try await fresh.firstSnapshot(of: restored) { $0.receivedBytes > Int64(2 * early) }
        await fresh.pause(restored)

        let resaved = try JSONDecoder().decode(PartialFileManifest.self, from: Data(contentsOf: manifestURL))
        #expect(resaved.connections == 16)
    }

    @Test func aRestoredDownloadKeepsItsNameConflictPolicy() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 47)
        var options = RequestOptions()
        options.nameConflictPolicy = .replace
        let (engine, id, folder) = try await startHeld(server, file: Self.heldFile(data), at: "/report.bin", options: options)
        await engine.pause(id)
        let package = try TestFiles.partialFile(in: folder)
        try Data("old".utf8).write(to: folder.appending(path: "report.bin"))

        let fresh = DownloadEngine(configuration: .fast)
        let restored = try await fresh.restore(partialFile: package)
        server.releaseHeldResponses()
        await fresh.resume(restored)
        let finished = try await fresh.completedOrFailed(restored)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "report.bin")
        #expect(try TestFiles.sha256(of: folder.appending(path: "report.bin")) == TestFiles.sha256(data))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.bin"])
    }

    @Test func aManifestFromBeforeTheNameConflictPolicyKeepsBoth() throws {
        var older = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.manifest())) as? [String: Any])
        older["formatVersion"] = 2
        older["nameConflictPolicy"] = nil
        let package = try Self.writePackage(Self.manifest(), in: try TestFiles.makeFolder())
        try JSONSerialization.data(withJSONObject: older).write(to: package.appending(path: "manifest.json"))

        let manifest = try PartialFile.readManifest(in: package)

        #expect(manifest.nameConflictPolicy == nil)
        #expect(PartialFileManifest.currentFormatVersion == 3)
    }
}
