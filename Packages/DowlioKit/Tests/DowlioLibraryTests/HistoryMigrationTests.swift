import DowlioCore
import DowlioStore
import DowlioTestSupport
import Foundation
import SQLite3
import Testing

struct HistoryMigrationTests {
    @Test func historyFromBeforeTheRenameKeepsWhichDownloadsUsedCookies() throws {
        let file = try TestFiles.makeFolder().appending(path: "Dowlio.sqlite")
        var options = RequestOptions()
        options.cookies = [Cookie(name: "session", value: "1")]
        let id = UUID()
        do {
            let store = try DownloadStore(databaseAt: file)
            try store.save(StoredDownload(
                id: id, sourceURL: URL(string: "https://example.com/a.pdf")!, destination: .folder(file.deletingLastPathComponent()),
                options: options, state: .paused, addedAt: Date()
            ))
        }
        try Self.run("""
            ALTER TABLE download RENAME COLUMN usedCookies TO usedSignIn;
            DELETE FROM grdb_migrations WHERE identifier = 'used cookies';
            """, on: file)

        let reopened = try DownloadStore(databaseAt: file)

        #expect(try reopened.all().first { $0.id == id }?.usedCookies == true)
    }

    @Test func historyFromBeforeMediaSourcesKeepsEveryDownloadAsItsFile() throws {
        let file = try TestFiles.makeFolder().appending(path: "Dowlio.sqlite")
        let link = URL(string: "https://example.com/a.pdf")!
        let id = UUID()
        do {
            let store = try DownloadStore(databaseAt: file)
            try store.save(StoredDownload(
                id: id, sourceURL: link, destination: .folder(file.deletingLastPathComponent()),
                options: RequestOptions(), state: .paused, addedAt: Date()
            ))
        }
        try Self.run("""
            ALTER TABLE download DROP COLUMN mediaSource;
            DELETE FROM grdb_migrations WHERE identifier = 'media source';
            """, on: file)

        let reopened = try DownloadStore(databaseAt: file)

        #expect(try reopened.all().first { $0.id == id }?.source == .file(link))
    }

    private static func run(_ sql: String, on file: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else { throw SQLiteFailure() }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFailure() }
    }

    private struct SQLiteFailure: Error {}
}
