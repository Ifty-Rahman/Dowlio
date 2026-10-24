import Foundation
import GRDB

public struct BrowserPairing: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "browserPairing"

    public var id: UUID
    public var browserName: String
    public var extensionID: String
    public var extensionVersion: String
    public var pairedAt: Date
    public var lastSeenAt: Date

    public init(id: UUID, browserName: String, extensionID: String, extensionVersion: String, pairedAt: Date) {
        self.id = id
        self.browserName = browserName
        self.extensionID = extensionID
        self.extensionVersion = extensionVersion
        self.pairedAt = pairedAt
        lastSeenAt = pairedAt
    }

    public mutating func markSeen(at time: Date, version: String? = nil) {
        lastSeenAt = time
        if let version { extensionVersion = version }
    }
}

extension DownloadStore {
    public func browserPairings() throws -> [BrowserPairing] {
        try read { try BrowserPairing.order(Column("pairedAt")).fetchAll($0) }
    }

    public func browserPairing(_ id: UUID) throws -> BrowserPairing? {
        try read { try BrowserPairing.fetchOne($0, key: id) }
    }

    public func save(_ pairing: BrowserPairing) throws {
        try write { try pairing.save($0) }
    }
}
