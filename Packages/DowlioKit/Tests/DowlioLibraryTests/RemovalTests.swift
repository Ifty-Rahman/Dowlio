import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

/// What Remove from List, Move to Trash and Clear Completed leave on disk.
@Suite(.timeLimit(.minutes(1)))
struct RemovalTests {
    @Test func removeFromListDropsACompletedRowAndKeepsTheFile() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 301), eTag: "\"m1\""), at: "/keep.pdf")

        let id = await fixture.add(server.url(for: "/keep.pdf"))
        _ = try await fixture.library.row(id) { $0.state == .completed }
        await fixture.library.removeFromList(id)

        #expect(try await fixture.library.firstRows { _ in true }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "keep.pdf").path))
        #expect(try await fixture.relaunched().library.firstRows { _ in true }.isEmpty)
    }

    @Test func removeFromListCancelsARowThatHasAPartialFile() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 4 * 1024 * 1024, seed: 302), holdAfterBytes: 128 * 1024, eTag: "\"m2\""), at: "/half.iso")

        let id = await fixture.add(server.url(for: "/half.iso"))
        _ = try await fixture.library.row(id) { $0.receivedBytes > 0 }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }
        await fixture.library.removeFromList(id)

        #expect(try await fixture.library.firstRows { _ in true }.isEmpty)
        #expect(TestFiles.partialFiles(in: fixture.folder).isEmpty)
    }

    @Test func moveToTrashSendsTheFinishedFileToTheTrashAndDropsTheRow() async throws {
        let trash = TrashSpy()
        let fixture = try await LibraryFixture(trash: trash.trash)
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 303), eTag: "\"m3\""), at: "/old.dmg")

        let id = await fixture.add(server.url(for: "/old.dmg"))
        _ = try await fixture.library.row(id) { $0.state == .completed }
        try await fixture.library.moveToTrash(id)

        #expect(trash.trashed.map(\.lastPathComponent) == ["old.dmg"])
        #expect(try await fixture.library.firstRows { _ in true }.isEmpty)
        #expect(try await fixture.relaunched().library.firstRows { _ in true }.isEmpty)
    }

    @Test func aFileTheTrashRefusesKeepsItsRow() async throws {
        let fixture = try await LibraryFixture(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 304), eTag: "\"m4\""), at: "/locked.zip")

        let id = await fixture.add(server.url(for: "/locked.zip"))
        _ = try await fixture.library.row(id) { $0.state == .completed }

        await #expect(throws: CocoaError.self) { try await fixture.library.moveToTrash(id) }
        #expect(try await fixture.library.firstRows { _ in true }.map(\.id) == [id])
    }

    @Test func clearCompletedRemovesOnlyCompletedRowsAndKeepsTheirFiles() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 305), eTag: "\"m5\""), at: "/done.txt")

        let done = await fixture.add(server.url(for: "/done.txt"))
        _ = try await fixture.library.row(done) { $0.state == .completed }
        let waiting = await fixture.add(server.url(for: "/done.txt"), startImmediately: false)
        _ = try await fixture.library.row(waiting) { _ in true }
        await fixture.library.clearCompleted()

        #expect(try await fixture.library.firstRows { _ in true }.map(\.id) == [waiting])
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "done.txt").path))
    }

    @Test func aFinishedFileDeletedWhileDowlioRunsIsFoundMissingOnTheNextCheck() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 306), eTag: "\"m6\""), at: "/gone.txt")

        let id = await fixture.add(server.url(for: "/gone.txt"))
        _ = try await fixture.library.row(id) { $0.state == .completed }
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "gone.txt"))
        await fixture.library.checkFinishedFiles()

        let row = try await fixture.library.row(id) { $0.isFileMissing }
        #expect(row.finishedFile == nil)
    }
}

final class TrashSpy: @unchecked Sendable {
    // @unchecked: `urls` is only read or written under `lock`.
    private let lock = NSLock()
    private var urls: [URL] = []

    var trashed: [URL] { lock.withLock { urls } }

    var trash: @Sendable (URL) throws -> Void {
        { [self] url in lock.withLock { urls.append(url) } }
    }
}
