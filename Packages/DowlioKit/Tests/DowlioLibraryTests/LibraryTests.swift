import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LibraryTests {
    @Test func anAddedLinkDownloadsAndItsRowEndsCompleted() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 3 * 1024 * 1024, seed: 201)
        server.serve(.init(data: data, eTag: "\"l1\""), at: "/files/Report.pdf")

        let id = await fixture.add(server.url(for: "/files/Report.pdf"))
        let row = try await fixture.library.row(id) { $0.state == .completed }

        #expect(row.fileName == "Report.pdf")
        #expect(row.stateWord == "Completed")
        #expect(row.detailLine == "3.15 MB")
        #expect(row.isNotSecure)
        #expect(row.host == "127.0.0.1")
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "Report.pdf")) == TestFiles.sha256(data))
    }

    @Test func aDownloadingRowShowsItsProgressAndConnections() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let held = 512 * 1024
        server.serve(.init(data: TestServer.makeData(size: 4 * 1024 * 1024, seed: 202), holdAfterBytes: held, eTag: "\"l2\""), at: "/big.iso")
        var options = RequestOptions()
        options.connections = 2

        let id = await fixture.add(server.url(for: "/big.iso"), options: options)
        let row = try await fixture.library.row(id) { $0.receivedBytes == Int64(2 * held) && $0.activeConnections == 2 }

        #expect(row.state == .downloading)
        #expect(row.stateWord == "Downloading")
        #expect(row.detailLine == "1.05 MB of 4.19 MB · 2 connections")
        #expect(row.segments.count == 2)
        #expect(row.badge == "ISO")
        server.releaseHeldResponses()
        _ = try await fixture.library.row(id) { $0.state == .completed }
    }

    @Test func aLinkAddedWithoutStartingStaysPausedUntilResumed() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024 * 1024, seed: 203)
        server.serve(.init(data: data, eTag: "\"l3\""), at: "/later.zip")

        let id = await fixture.add(server.url(for: "/later.zip"), startImmediately: false)
        let paused = try await fixture.library.row(id) { _ in true }

        #expect(paused.state == .paused)
        #expect(paused.fileName == "later.zip")
        #expect(server.requests.isEmpty)

        await fixture.library.resume(id)
        _ = try await fixture.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "later.zip")) == TestFiles.sha256(data))
    }

    @Test func pauseKeepsTheBytesAndResumeFinishesTheFile() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 204)
        let held = 256 * 1024
        server.serve(.init(data: data, holdAfterBytes: held, eTag: "\"l4\""), at: "/pause.bin")
        var options = RequestOptions()
        options.connections = 2

        let id = await fixture.add(server.url(for: "/pause.bin"), options: options)
        _ = try await fixture.library.row(id) { $0.receivedBytes == Int64(2 * held) }
        await fixture.library.pause(id)
        let paused = try await fixture.library.row(id) { $0.state == .paused }

        #expect(paused.receivedBytes == Int64(2 * held))
        #expect(paused.detailLine == "524 KB of 4.19 MB")

        server.releaseHeldResponses()
        await fixture.library.resume(id)
        _ = try await fixture.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "pause.bin")) == TestFiles.sha256(data))
    }

    @Test func cancelDeletesThePartialFileAndLeavesNoRecord() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 4 * 1024 * 1024, seed: 205), holdAfterBytes: 128 * 1024, eTag: "\"l5\""), at: "/drop.bin")

        let id = await fixture.add(server.url(for: "/drop.bin"))
        _ = try await fixture.library.row(id) { $0.receivedBytes > 0 }
        await fixture.library.cancel(id)
        let rows = try await fixture.library.firstRows { _ in true }

        #expect(rows.isEmpty)
        #expect(TestFiles.partialFiles(in: fixture.folder).isEmpty)
        let relaunched = try await fixture.relaunched()
        #expect(try await relaunched.library.firstRows { _ in true }.isEmpty)
    }

    @Test func aFailedRowSaysTheReasonAndOneNextStep() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()

        let id = await fixture.add(server.url(for: "/missing.zip"))
        let row = try await fixture.library.row(id) { $0.stateWord == "Failed" }

        #expect(row.state == .failed(.notFound))
        #expect(row.detailLine == "Not found · The link may have been removed")
    }

    @Test func retryContinuesAFailedDownload() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 207)
        server.serve(.init(data: data, eTag: "\"l7\"", dropFirst: .init(afterBytes: 128 * 1024, count: 1)), at: "/again.bin")
        var options = RequestOptions()
        options.connections = 1
        options.maximumFailures = 1

        let id = await fixture.add(server.url(for: "/again.bin"), options: options)
        let failed = try await fixture.library.row(id) { $0.stateWord == "Failed" }
        #expect(failed.state == .failed(.tooManyRetries))

        await fixture.library.retry(id)
        _ = try await fixture.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "again.bin")) == TestFiles.sha256(data))
    }

    @Test func cancelLeavesACompletedDownloadAlone() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 208), eTag: "\"l8\""), at: "/done.txt")

        let id = await fixture.add(server.url(for: "/done.txt"))
        _ = try await fixture.library.row(id) { $0.state == .completed }
        await fixture.library.cancel(id)

        #expect(try await fixture.library.firstRows { _ in true }.map(\.id) == [id])
        #expect(try await fixture.relaunched().library.firstRows { _ in true }.map(\.id) == [id])
    }

    @Test func theContentTypeDecidesTheCategoryWhenTheNameDoesnt() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let headers = ["Content-Disposition": #"attachment; filename="talk""#, "Content-Type": "video/mp4"]
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 209), eTag: "\"l9\"", headers: headers), at: "/watch")

        let id = await fixture.add(server.url(for: "/watch"))
        let row = try await fixture.library.row(id) { $0.state == .completed }

        #expect(row.category == .video)
        #expect(try await fixture.relaunched().library.row(id) { _ in true }.category == .video)
    }

    @Test func aDownloadAddedFromTheSheetKeepsTheChosenNameFolderAndOptions() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024, seed: 210)
        server.serve(.init(data: data, eTag: "\"s1\""), at: "/download?id=9")
        let elsewhere = fixture.folder.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var options = RequestOptions()
        options.fileName = "Meeting notes.txt"
        options.referrer = URL(string: "https://example.com/notes")
        options.userAgent = "Dowlio test"
        options.connections = 1

        let id = await fixture.library.add(
            server.url(for: "/download?id=9"), destination: .folder(elsewhere), options: options, startImmediately: false
        )
        let waiting = try await fixture.library.row(id) { _ in true }
        #expect(waiting.fileName == "Meeting notes.txt")
        #expect(waiting.state == .paused)

        await fixture.library.resume(id)
        _ = try await fixture.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: elsewhere.appending(path: "Meeting notes.txt")) == TestFiles.sha256(data))
        #expect(server.requests.allSatisfy { $0.headers["referer"] == "https://example.com/notes" && $0.headers["user-agent"] == "Dowlio test" })
    }

    @Test func theLibraryInspectsALinkWithoutAddingIt() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 2048, seed: 211), eTag: "\"s2\""), at: "/peek.zip")

        let inspection = try await fixture.library.inspect(server.url(for: "/peek.zip"))

        #expect(inspection.fileName == "peek.zip")
        #expect(inspection.totalBytes == 2048)
        #expect(try await fixture.library.firstRows { _ in true }.isEmpty)
    }

    @Test func aRowIsPublishedOnlyWhenSomethingItShowsChanges() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 2 * 1024 * 1024, seed: 206), eTag: "\"l6\""), at: "/steady.bin")

        let recording = Task {
            var all: [[DownloadRow]] = []
            for await rows in await fixture.library.rows() {
                all.append(rows)
                if rows.first?.state == .completed { break }
            }
            return all
        }
        await fixture.add(server.url(for: "/steady.bin"))
        let published = await recording.value

        #expect(zip(published, published.dropFirst()).allSatisfy { $0 != $1 })
    }
}

/// Quitting and opening Dowlio again: a new engine and library on the same database and folders.
@Suite(.timeLimit(.minutes(1)))
struct RelaunchTests {
    @Test func anUnfinishedDownloadComesBackPausedAndResumeFinishesIt() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 211)
        let held = 256 * 1024
        server.serve(.init(data: data, holdAfterBytes: held, eTag: "\"r1\""), at: "/long.iso")
        var options = RequestOptions()
        options.connections = 2

        let id = await fixture.add(server.url(for: "/long.iso"), options: options)
        _ = try await fixture.library.row(id) { $0.receivedBytes == Int64(2 * held) }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }

        #expect(restored.state == .paused)
        #expect(restored.receivedBytes == Int64(2 * held))
        #expect(restored.totalBytes == Int64(data.count))

        server.releaseHeldResponses()
        await relaunched.library.resume(id)
        _ = try await relaunched.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "long.iso")) == TestFiles.sha256(data))
    }

    @Test func aFailedDownloadComesBackPausedAndResumeRetriesIt() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 212)
        server.serve(.init(data: data, eTag: "\"r2\"", dropFirst: .init(afterBytes: 128 * 1024, count: 1)), at: "/flaky.bin")
        var options = RequestOptions()
        options.connections = 1
        options.maximumFailures = 1

        let id = await fixture.add(server.url(for: "/flaky.bin"), options: options)
        _ = try await fixture.library.row(id) { $0.stateWord == "Failed" }

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }
        #expect(restored.state == .paused)

        await relaunched.library.resume(id)
        _ = try await relaunched.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "flaky.bin")) == TestFiles.sha256(data))
    }

    @Test func aDownloadWhosePartialFileWasDeletedStartsOverFromItsLink() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 213)
        server.serve(.init(data: data, holdAfterBytes: 128 * 1024, eTag: "\"r3\""), at: "/gone.bin")
        var options = RequestOptions()
        options.connections = 1

        let id = await fixture.add(server.url(for: "/gone.bin"), options: options)
        _ = try await fixture.library.row(id) { $0.receivedBytes > 0 }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }
        try FileManager.default.removeItem(at: TestFiles.partialFile(in: fixture.folder))

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }
        #expect(restored.state == .paused)

        server.releaseHeldResponses()
        let requestsBefore = server.requests.count
        await relaunched.library.resume(id)
        _ = try await relaunched.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "gone.bin")) == TestFiles.sha256(data))
        #expect(server.requests.dropFirst(requestsBefore).last?.headers["range"] == "bytes=0-\(data.count - 1)")
    }

    @Test func aCompletedDownloadStaysInHistoryAndSaysWhenItsFileIsGone() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 214), eTag: "\"r4\""), at: "/kept.txt")
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 215), eTag: "\"r5\""), at: "/moved.txt")

        let kept = await fixture.add(server.url(for: "/kept.txt"))
        _ = try await fixture.library.row(kept) { $0.state == .completed }
        let moved = await fixture.add(server.url(for: "/moved.txt"))
        _ = try await fixture.library.row(moved) { $0.state == .completed }
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "moved.txt"))

        let relaunched = try await fixture.relaunched()
        let rows = try await relaunched.library.firstRows { $0.count == 2 }

        #expect(rows.map(\.fileName) == ["moved.txt", "kept.txt"])
        #expect(rows[0].isFileMissing)
        #expect(rows[0].detailLine == "File not found")
        #expect(rows[0].finishedFile == nil)
        #expect(!rows[1].isFileMissing)
        #expect(rows[1].finishedFile?.lastPathComponent == "kept.txt")
    }

    @Test func aDownloadThatNeverStartedKeepsItsReferrerButNotItsCookies() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 216), eTag: "\"r6\""), at: "/private.pdf")
        var options = RequestOptions()
        options.referrer = URL(string: "https://example.com/page")
        options.cookies = [Cookie(name: "session", value: "secret")]

        let id = await fixture.add(server.url(for: "/private.pdf"), options: options, startImmediately: false)
        _ = try await fixture.library.row(id) { _ in true }

        let relaunched = try await fixture.relaunched()
        await relaunched.library.resume(id)
        _ = try await relaunched.library.row(id) { $0.state == .completed }

        #expect(server.requests.allSatisfy { $0.headers["referer"] == "https://example.com/page" })
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
        let database = try String(decoding: Data(contentsOf: fixture.databaseURL), as: UTF8.self)
        #expect(!database.contains("secret"))
    }
}

