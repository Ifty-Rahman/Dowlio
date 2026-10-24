import DowlioCore
import DowlioEngine
import DowlioLibrary
import DowlioStore
import DowlioTestSupport
import Foundation

/// A library on a database and download folder in a fresh temporary folder. `relaunched()` is the
/// same Mac after quitting: a new engine and library on the same database and folders.
struct LibraryFixture {
    let library: Library
    let engine: DownloadEngine
    let databaseURL: URL
    let folder: URL

    init(trash: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws {
        let base = try TestFiles.makeFolder()
        let folder = base.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await self.init(databaseURL: base.appending(path: "Dowlio.sqlite"), folder: folder, trash: trash)
    }

    private init(
        databaseURL: URL, folder: URL, trash: @escaping @Sendable (URL) throws -> Void, maximumFailures: Int? = nil
    ) async throws {
        self.databaseURL = databaseURL
        self.folder = folder
        engine = DownloadEngine(configuration: .fast)
        library = Library(engine: engine, store: try DownloadStore(databaseAt: databaseURL), trash: trash)
        await library.start(maximumFailures: maximumFailures)
    }

    /// The same Mac after quitting. `maximumFailures` is the retry setting in force at launch.
    func relaunched(maximumFailures: Int? = nil) async throws -> LibraryFixture {
        try await LibraryFixture(databaseURL: databaseURL, folder: folder, trash: { _ in }, maximumFailures: maximumFailures)
    }

    func add(_ url: URL, options: RequestOptions = RequestOptions(), startImmediately: Bool = true) async -> DownloadID {
        await library.add(url, destination: .folder(folder), options: options, startImmediately: startImmediately)
    }
}

enum LibraryTestError: Error {
    case rowsEnded
}

extension Library {
    /// Waits for the first published rows that match `condition`.
    func firstRows(where condition: @Sendable ([DownloadRow]) -> Bool) async throws -> [DownloadRow] {
        for await rows in rows() where condition(rows) {
            return rows
        }
        throw LibraryTestError.rowsEnded
    }

    /// Waits for the row of `id` to match `condition`.
    func row(_ id: DownloadID, where condition: @Sendable (DownloadRow) -> Bool) async throws -> DownloadRow {
        let rows = try await firstRows { $0.first { $0.id == id }.map(condition) ?? false }
        return rows.first { $0.id == id }!
    }
}
