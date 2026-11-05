import DowlioCore
import Foundation

/// Picks out downloads that become Completed while Dowlio watches. Completed rows already there
/// the first time, such as History at launch, don't count.
public struct FinishWatcher: Sendable {
    private var unfinished: Set<DownloadID> = []

    public init() {}

    public mutating func newlyFinished(in rows: [DownloadRow]) -> [DownloadRow] {
        let finished = rows.filter { $0.state == .completed && unfinished.contains($0.id) }
        unfinished = Set(rows.filter { $0.state != .completed }.map(\.id))
        return finished
    }
}

public struct ProblemWatcher: Sendable {
    private var needing: Set<DownloadID>?

    public init() {}

    public mutating func newProblems(in rows: [DownloadRow]) -> [DownloadRow] {
        let current = Set(rows.filter(\.needsAttention).map(\.id))
        defer { needing = current }
        guard let needing else { return [] }
        return rows.filter { current.contains($0.id) && !needing.contains($0.id) }
    }
}

public struct NoticeGrouper: Sendable {
    public static let window: TimeInterval = 5

    private var group = UUID()
    private var rows: [DownloadRow] = []
    private var firstAt: Date?

    public init() {}

    public mutating func add(_ row: DownloadRow, at date: Date) -> (group: UUID, rows: [DownloadRow]) {
        if let firstAt, date.timeIntervalSince(firstAt) < Self.window {
            rows.append(row)
        } else {
            group = UUID()
            rows = [row]
            firstAt = date
        }
        return (group, rows)
    }
}

public struct FinishNotice: Equatable, Sendable {
    public let rows: [DownloadRow]
    public let group: UUID

    public init(rows: [DownloadRow], group: UUID = UUID()) {
        self.rows = rows
        self.group = group
    }

    public var title: String {
        rows.count == 1 ? "Download finished" : "\(rows.count) downloads finished"
    }

    public var body: String {
        FileNames.sentence(rows.map(\.fileName))
    }

    /// "Then" in Settings runs for a single finish only, so several never open a pile of files.
    public var runsThenAction: Bool { rows.count == 1 }

    /// The file Show in Finder, Open and "Then" act on. Only a single finish has one.
    public var singleFile: URL? {
        rows.count == 1 ? rows[0].finishedFile : nil
    }
}

public struct ProblemNotice: Equatable, Sendable {
    public let rows: [DownloadRow]
    public let group: UUID

    public init(rows: [DownloadRow], group: UUID = UUID()) {
        self.rows = rows
        self.group = group
    }

    public var title: String {
        let failed = rows.allSatisfy { if case .failed = $0.state { true } else { false } }
        if rows.count == 1 { return failed ? "Download failed" : "Download can't resume" }
        return failed ? "\(rows.count) downloads failed" : "\(rows.count) downloads need attention"
    }

    public var body: String {
        guard rows.count == 1 else { return FileNames.sentence(rows.map(\.fileName)) }
        let row = rows[0]
        switch row.state {
        case .failed(let error):
            let failure = FailureText(error, isMedia: row.isMedia)
            return "\(row.fileName)\n\(failure.reason). \(failure.nextStep)."
        default:
            return "\(row.fileName)\nSend the \(row.isMedia ? "page" : "link") again from your browser."
        }
    }

    public var retryable: DownloadID? {
        guard rows.count == 1, case .failed = rows[0].state else { return nil }
        return rows[0].id
    }
}

/// What Settings › Notifications' "Then" does after a single download finishes.
public enum ThenAction: String, CaseIterable, Sendable {
    case nothing
    case showInFinder

    /// A saved choice, with anything unknown read as doing nothing.
    public init(saved: String) {
        self = ThenAction(rawValue: saved) ?? .nothing
    }

    public var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .showInFinder: "Show in Finder"
        }
    }
}

public enum NotificationClick: String, CaseIterable, Sendable {
    case openDowlio
    case showInFinder
    case openFile

    public enum Target: Equatable, Sendable {
        case dowlio
        case showInFinder(URL)
        case open(URL)
    }

    public init(saved: String) {
        self = NotificationClick(rawValue: saved) ?? .openDowlio
    }

    public var title: String {
        switch self {
        case .openDowlio: "Open Dowlio"
        case .showInFinder: "Show in Finder"
        case .openFile: "Open the file"
        }
    }

    public func target(for file: URL?) -> Target {
        guard let file else { return .dowlio }
        switch self {
        case .openDowlio: return .dowlio
        case .showInFinder: return .showInFinder(file)
        case .openFile: return .open(file)
        }
    }
}

public struct UpdateNotice: Equatable, Sendable {
    public var version: String

    public init(version: String) {
        self.version = version
    }

    public var title: String { "A new version of Dowlio is available" }
    public var body: String { "Dowlio \(version) is ready to install. Click to see what's new." }
    public var menuBarLine: String { "Dowlio \(version) is available" }
    public var menuTitle: String { "Update to Dowlio \(version)…" }
    public var dockBadge: String { "1" }
}

public enum FileNames {
    public static func sentence(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }
}
