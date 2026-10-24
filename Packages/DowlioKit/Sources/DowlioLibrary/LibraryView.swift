import DowlioCore
import Foundation

public enum LibraryFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case downloading
    case paused
    case queued
    case failed
    case completed

    public var title: String {
        switch self {
        case .all: "All Downloads"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .queued: "Queued"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }

    /// Retrying counts as Downloading: it's still on its way.
    public func includes(_ row: DownloadRow) -> Bool {
        switch (self, row.state) {
        case (.all, _), (.downloading, .downloading), (.downloading, .retrying), (.paused, .paused),
             (.queued, .queued), (.failed, .failed), (.completed, .completed): true
        default: false
        }
    }
}

/// The library list as the window shows it: filtered by the sidebar, then by search.
public struct LibraryView: Equatable, Sendable {
    public let all: [DownloadRow]
    public let filter: LibraryFilter
    public let search: String

    public init(rows: [DownloadRow], filter: LibraryFilter, search: String) {
        all = rows
        self.filter = filter
        self.search = search
    }

    public var rows: [DownloadRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return all.filter { row in
            filter.includes(row) && (query.isEmpty || Self.matches(row, query))
        }
    }

    public var counts: [LibraryFilter: Int] {
        Dictionary(uniqueKeysWithValues: LibraryFilter.allCases.map { filter in (filter, all.count { filter.includes($0) }) })
    }

    /// "3 downloads · 12.4 MB/s": the rows shown, then the speed of every download, shown or not.
    public var summary: String {
        let count = rows.count
        let items = count == 1 ? "1 download" : "\(count) downloads"
        let speed = all.reduce(Int64(0)) { $0 + ($1.speedText == nil ? 0 : $1.bytesPerSecond) }
        return speed > 0 ? "\(items) · \(ByteText.string(speed))/s" : items
    }

    public var canPauseAll: Bool { all.contains(where: \.canPause) }
    public var canResumeAll: Bool { all.contains { $0.state == .paused || $0.state == .queued } }
    public var canClearCompleted: Bool { all.contains { $0.state == .completed } }

    private static func matches(_ row: DownloadRow, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return row.fileName.range(of: query, options: options) != nil
            || (row.host?.range(of: query, options: options) ?? nil) != nil
    }
}

public enum FreeSpaceText {
    public static func string(_ bytes: Int64) -> String {
        "\(ByteText.string(bytes)) free"
    }
}
