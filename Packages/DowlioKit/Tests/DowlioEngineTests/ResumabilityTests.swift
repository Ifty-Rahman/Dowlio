import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Whether a download can resume, after a restart too, and the finishing check on a restored
/// partial file.
@Suite(.timeLimit(.minutes(1)))
struct ResumabilityTests {
    static let size = 4 * 1024 * 1024
    static let held = 256 * 1024

    /// The one partial file in `folder`.
    private func partialFile(in folder: URL) throws -> URL {
        let packages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dowlio" }
        return try #require(packages.count == 1 ? packages.first : nil)
    }

    @Test func aRestoredDownloadFromAServerWithoutRangesCantResumeAndStartsOver() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 51)
        server.serve(.init(data: data, supportsRanges: false, holdAfterBytes: Self.held, eTag: "\"w1\""), at: "/whole.bin")
        let folder = try TestFiles.makeFolder()
        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: "/whole.bin"), to: folder)
        let downloading = try await engine.firstSnapshot(of: id) { $0.receivedBytes == Int64(Self.held) }
        #expect(downloading.totalBytes == Int64(Self.size))
        #expect(!downloading.canResume)
        await engine.pause(id)
        let package = try partialFile(in: folder)

        let fresh = DownloadEngine(configuration: .fastWithHolds)
        let restored = try await fresh.restore(partialFile: package)
        let snapshot = try await fresh.firstSnapshot(of: restored) { _ in true }
        #expect(snapshot.state == .paused)
        #expect(!snapshot.canResume)

        server.releaseHeldResponses()
        let requestsBeforeResume = server.requests.count
        await fresh.resume(restored)
        let finished = try await fresh.finished(restored)

        #expect(finished.state == .completed)
        #expect(finished.receivedBytes == Int64(Self.size))
        #expect(try TestFiles.sha256(of: folder.appending(path: "whole.bin")) == TestFiles.sha256(data))
        // One request fetched the whole file again.
        #expect(server.requests.count == requestsBeforeResume + 1)
    }

    @Test func aRestoredFormatOneManifestCantResume() async throws {
        let folder = try TestFiles.makeFolder()
        let package = folder.appending(path: "old.bin.dowlio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(count: 1024).write(to: package.appending(path: "data"))
        // Format 1 didn't record whether the server supports ranges.
        let manifest = PartialFileManifest(
            formatVersion: 1,
            downloadID: UUID().uuidString,
            originalURL: URL(string: "http://127.0.0.1:1/old.bin")!,
            finalURL: URL(string: "http://127.0.0.1:1/old.bin")!,
            validator: "\"o1\"",
            totalBytes: 2048,
            fileName: "old.bin",
            connections: 8,
            segments: [.init(start: 0, end: 2047, received: 1024)]
        )
        try JSONEncoder().encode(manifest).write(to: package.appending(path: "manifest.json"))

        let engine = DownloadEngine()
        let restored = try await engine.restore(partialFile: package)
        let snapshot = try await engine.firstSnapshot(of: restored) { _ in true }

        #expect(snapshot.state == .paused)
        #expect(!snapshot.canResume)
    }

    @Test(arguments: [
        (nil, nil, false),
        ("W/\"weak\"", nil, false),
        ("\"strong\"", nil, true),
        (nil, "Wed, 21 Oct 2026 07:28:00 GMT", true),
    ] as [(String?, String?, Bool)])
    func onlyARangedDownloadWithAStrongValidatorCanResume(eTag: String?, lastModified: String?, canResume: Bool) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 52)
        server.serve(.init(data: data, holdAfterBytes: Self.held, eTag: eTag, lastModified: lastModified), at: "/v.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2

        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: "/v.bin"), to: folder, options: options)
        let downloading = try await engine.firstSnapshot(of: id) { $0.receivedBytes > 0 }

        #expect(downloading.canResume == canResume)
        server.releaseHeldResponses()
        #expect(try await engine.finished(id).state == .completed)
    }

    @Test func aRestoredDownloadWithoutAValidatorCantResume() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 53)
        server.serve(.init(data: data, holdAfterBytes: Self.held), at: "/nov.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2
        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: "/nov.bin"), to: folder, options: options)
        _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes == Int64(2 * Self.held) }
        await engine.pause(id)

        let fresh = DownloadEngine(configuration: .fastWithHolds)
        let restored = try await fresh.restore(partialFile: try partialFile(in: folder))
        let snapshot = try await fresh.firstSnapshot(of: restored) { _ in true }

        #expect(!snapshot.canResume)
    }
}
