import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct OneConnectionDownloadTests {
    @Test func downloadCompletesWithTheServedBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 3 * 1024 * 1024)
        server.serve(.init(data: data), at: "/files/archive.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/files/archive.zip"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        let file = folder.appending(path: "archive.zip")
        #expect(try TestFiles.sha256(of: file) == TestFiles.sha256(data))
    }

    @Test func firstRequestProbesForRangeSupport() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024)), at: "/probe.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/probe.bin"), to: folder)
        _ = try await engine.completedOrFailed(id)

        let probe = try #require(server.requests.first)
        #expect(probe.method == "GET")
        #expect(probe.headers["range"] == "bytes=0-0")
        #expect(probe.headers["accept-encoding"] == "identity")
    }

    @Test func serverWithoutRangeSupportStillCompletes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 7)
        server.serve(.init(data: data, supportsRanges: false), at: "/plain.iso")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/plain.iso"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "plain.iso")) == TestFiles.sha256(data))
        #expect(server.requests.count == 1)
    }

    @Test func bytesGoIntoAPartialFileUntilTheDownloadCompletes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 3)
        let held = 512 * 1024
        server.serve(.init(data: data, holdAfterBytes: held), at: "/video.mp4")
        let folder = try TestFiles.makeFolder()
        let partial = folder.appending(path: "video.mp4.dowlio")
        let destination = folder.appending(path: "video.mp4")

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/video.mp4"), to: folder)
        let midway = try await engine.firstSnapshot(of: id) { $0.receivedBytes >= Int64(held) }

        #expect(midway.state == .downloading)
        #expect(midway.totalBytes == Int64(data.count))
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        server.releaseHeldResponses()
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.receivedBytes == Int64(data.count))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try TestFiles.sha256(of: destination) == TestFiles.sha256(data))
    }

    @Test func anExistingFileIsNeverOverwritten() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024)
        server.serve(.init(data: data), at: "/report.pdf")
        let folder = try TestFiles.makeFolder()
        let existing = folder.appending(path: "report.pdf")
        let original = Data("the user's own report".utf8)
        try original.write(to: existing)

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/report.pdf"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "report 2.pdf")
        #expect(try Data(contentsOf: existing) == original)
        #expect(try TestFiles.sha256(of: folder.appending(path: "report 2.pdf")) == TestFiles.sha256(data))
    }

    /// Replies that end early are resumed from the missing bytes, so the file that
    /// goes into place is complete, never short.
    @Test func aShortReplyIsResumedNeverPutInPlaceShort() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024)
        server.serve(.init(data: data, shortRangeBodiesBy: 100), at: "/short.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/short.bin"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "short.bin")) == TestFiles.sha256(data))
    }

    /// A download that ends with bytes missing never puts its file in place. Every reply
    /// drops partway, so the retries run out long before the last byte arrives.
    @Test(arguments: [true, false])
    func aDownloadThatEndsWithBytesMissingNeverPutsItsFileInPlace(rangesSupported: Bool) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 51)
        let dropEveryReply = TestServer.BodyFault(afterBytes: 64 * 1024, count: .max)
        server.serve(.init(data: data, supportsRanges: rangesSupported, dropFirst: dropEveryReply), at: "/half.iso")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/half.iso"), to: folder, options: options)
        var states: [DownloadState] = []
        var last: DownloadSnapshot?
        for await snapshot in await engine.snapshots(of: id) {
            states.append(snapshot.state)
            last = snapshot
            if case .failed = snapshot.state { break }
        }

        let failed = try #require(last)
        #expect(failed.state == .failed(.tooManyRetries))
        #expect(failed.receivedBytes < Int64(data.count))
        #expect(!states.contains(.finalizing))
        #expect(!states.contains(.completed))
        // No finished file, and the partial file stays for Retry.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["half.iso.dowlio"])
    }

    @Test func theSnapshotStreamEndsAfterCompleted() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024)
        server.serve(.init(data: data), at: "/notes.txt")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/notes.txt"), to: folder)
        var states: [DownloadState] = []
        for await snapshot in await engine.snapshots(of: id) {
            states.append(snapshot.state)
        }
        #expect(states.last == .completed)
        #expect(states.contains(.downloading))

        var late: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) {
            late.append(snapshot)
        }
        #expect(late.count == 1)
        #expect(late.first?.state == .completed)
        #expect(late.first?.fileName == "notes.txt")
        #expect(late.first?.totalBytes == Int64(data.count))
    }

    @Test func aMissingFileLeavesNoPartialFileBehind() async throws {
        let server = try await TestServer()
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/gone.zip"), to: folder)
        _ = try await engine.completedOrFailed(id)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aSecondDownloadOfTheSameFileGetsItsOwnPartialFile() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024)
        server.serve(.init(data: data, holdAfterBytes: 1024), at: "/twice.iso")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let first = await engine.add(url: server.url(for: "/twice.iso"), to: folder)
        let second = await engine.add(url: server.url(for: "/twice.iso"), to: folder)
        _ = try await engine.firstSnapshot(of: first) { $0.receivedBytes > 0 }
        let secondMidway = try await engine.firstSnapshot(of: second) { $0.receivedBytes > 0 }

        #expect(secondMidway.state == .downloading)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "twice.iso.dowlio").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "twice.iso 2.dowlio").path))
        server.releaseHeldResponses()
        _ = try await engine.completedOrFailed(first)
        _ = try await engine.completedOrFailed(second)
    }

    @Test func theFileIsNamedFromTheFinalURLAfterRedirects() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024)
        server.serve(.init(data: data), at: "/releases/app-1.2.dmg")
        server.redirect("/download/latest", to: "/releases/app-1.2.dmg")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/download/latest"), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "app-1.2.dmg")
        #expect(try TestFiles.sha256(of: folder.appending(path: "app-1.2.dmg")) == TestFiles.sha256(data))
    }
}
