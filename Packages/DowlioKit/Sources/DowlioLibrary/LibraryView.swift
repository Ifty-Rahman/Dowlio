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

/// What the sidebar has chosen: a state in the Library group or one of the Categories. It's
/// saved as text, such as "filter.paused" or "category.video".
public enum LibrarySelection: Hashable, Sendable, RawRepresentable {
    case filter(LibraryFilter)
    case category(FileCategory)

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "filter": guard let filter = LibraryFilter(rawValue: parts[1]) else { return nil }; self = .filter(filter)
        case "category": guard let category = FileCategory(rawValue: parts[1]) else { return nil }; self = .category(category)
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .filter(let filter): "filter.\(filter.rawValue)"
        case .category(let category): "category.\(category.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .filter(let filter): filter.title
        case .category(let category): category.folderName
        }
    }

    public func includes(_ row: DownloadRow) -> Bool {
        switch self {
        case .filter(let filter): filter.includes(row)
        case .category(let category): row.category == category
        }
    }
}

/// The library list as the window shows it: filtered by the sidebar, then by search.
public struct LibraryView: Equatable, Sendable {
    public let all: [DownloadRow]
    public let selection: LibrarySelection
    public let search: String

    public init(rows: [DownloadRow], selection: LibrarySelection, search: String) {
        all = rows
        self.selection = selection
        self.search = search
    }

    public var rows: [DownloadRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return all.filter { row in
            selection.includes(row) && (query.isEmpty || Self.matches(row, query))
        }
    }

    public var counts: [LibraryFilter: Int] {
        Dictionary(uniqueKeysWithValues: LibraryFilter.allCases.map { filter in (filter, all.count { filter.includes($0) }) })
    }

    public var categoryCounts: [FileCategory: Int] {
        Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { category in (category, all.count { $0.category == category }) })
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
