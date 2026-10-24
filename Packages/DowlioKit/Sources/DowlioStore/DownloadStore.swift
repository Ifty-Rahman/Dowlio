import DowlioCore
import Foundation
import GRDB

/// One download as History keeps it. It never holds cookies or any header but the referrer and
/// user agent, which the partial file's manifest keeps too.
public struct StoredDownload: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "download"

    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        /// Waiting for a free slot. The engine hasn't seen it yet.
        case queued
        case paused
        /// Probing, downloading, retrying or finalizing.
        case downloading
        case failed
        case completed
    }

    public var id: UUID
    public var sourceURL: URL
    public var displayHost: String?
    public var fileName: String
    /// The folder the finished file goes into. With category folders, it's the root until the
    /// probe chooses the category's folder.
    public var folder: URL
    public var destinationRoot: URL
    public var sortsIntoCategoryFolders: Bool
    public var category: FileCategory?
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var state: State
    public var addedAt: Date
    public var completedAt: Date?
    public var partialFile: URL?
    public var isNotSecure: Bool
    public var wasSkipped: Bool
    public var connections: Int
    public var opensAllConnectionsAtOnce: Bool
    public var nameConflictPolicy: NameConflictPolicy
    public var referrer: URL?
    public var userAgent: String?
    public var maximumFailures: Int?

    public init(
        id: UUID,
        sourceURL: URL,
        destination: Destination,
        options: RequestOptions,
        state: State,
        addedAt: Date
    ) {
        self.id = id
        self.sourceURL = sourceURL
        displayHost = sourceURL.host(percentEncoded: false)?.lowercased()
        let last = sourceURL.lastPathComponent
        fileName = last.isEmpty || last == "/" ? "download" : last
        folder = destination.root
        destinationRoot = destination.root
        if case .categoryFolders = destination { sortsIntoCategoryFolders = true } else { sortsIntoCategoryFolders = false }
        totalBytes = nil
        receivedBytes = 0
        self.state = state
        self.addedAt = addedAt
        isNotSecure = sourceURL.scheme?.lowercased() == "http"
        wasSkipped = false
        connections = options.connections
        opensAllConnectionsAtOnce = options.openExtraConnections == .allAtOnce
        nameConflictPolicy = options.nameConflictPolicy
        referrer = options.referrer
        userAgent = options.userAgent
        maximumFailures = options.maximumFailures
    }

    public var destination: Destination {
        sortsIntoCategoryFolders ? .categoryFolders(under: destinationRoot) : .folder(destinationRoot)
    }

    /// The options the download was added with. Cookies are never stored, so there are none.
    public var options: RequestOptions {
        var options = RequestOptions()
        options.connections = connections
        options.openExtraConnections = opensAllConnectionsAtOnce ? .allAtOnce : .afterFirstConnectionStarts
        options.nameConflictPolicy = nameConflictPolicy
        options.referrer = referrer
        options.userAgent = userAgent
        options.maximumFailures = maximumFailures
        return options
    }
}

extension FileCategory: DatabaseValueConvertible {}
extension NameConflictPolicy: DatabaseValueConvertible {}

/// History on disk: one SQLite database, migrated when it opens.
public final class DownloadStore: Sendable {
    private let database: DatabaseQueue

    public init(databaseAt url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(database)
    }

    /// Every download, newest added first.
    public func all() throws -> [StoredDownload] {
        try database.read { try StoredDownload.order(Column("addedAt").desc).fetchAll($0) }
    }

    public func save(_ download: StoredDownload) throws {
        try database.write { try download.save($0) }
    }

    public func delete(_ id: UUID) throws {
        _ = try database.write { try StoredDownload.deleteOne($0, key: id) }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("downloads") { db in
            try db.create(table: StoredDownload.databaseTableName) { table in
                table.primaryKey("id", .blob)
                table.column("sourceURL", .text).notNull()
                table.column("displayHost", .text)
                table.column("fileName", .text).notNull()
                table.column("folder", .text).notNull()
                table.column("destinationRoot", .text).notNull()
                table.column("sortsIntoCategoryFolders", .boolean).notNull()
                table.column("category", .text)
                table.column("totalBytes", .integer)
                table.column("receivedBytes", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("addedAt", .datetime).notNull().indexed()
                table.column("completedAt", .datetime)
                table.column("partialFile", .text)
                table.column("isNotSecure", .boolean).notNull()
                table.column("wasSkipped", .boolean).notNull()
                table.column("connections", .integer).notNull()
                table.column("opensAllConnectionsAtOnce", .boolean).notNull()
                table.column("nameConflictPolicy", .text).notNull()
                table.column("referrer", .text)
                table.column("userAgent", .text)
                table.column("maximumFailures", .integer)
            }
        }
        return migrator
    }
}
