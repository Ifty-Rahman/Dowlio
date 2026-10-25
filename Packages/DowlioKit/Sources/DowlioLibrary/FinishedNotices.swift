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

/// Groups finishes that come within five seconds of the first one, so they share one notice. The
/// window opens at the first finish, so a steady trickle never holds a notice back for ever.
public struct FinishGrouper: Sendable {
    public static let window: TimeInterval = 5

    private var waiting: [DownloadRow] = []
    private var firstFinish: Date?

    public init() {}

    public mutating func add(_ row: DownloadRow, at date: Date) {
        waiting.append(row)
        if firstFinish == nil { firstFinish = date }
    }

    public var dueDate: Date? {
        firstFinish.map { $0.addingTimeInterval(Self.window) }
    }

    public mutating func takeDue(at now: Date) -> FinishNotice? {
        guard let dueDate, now >= dueDate, !waiting.isEmpty else { return nil }
        defer {
            waiting = []
            firstFinish = nil
        }
        return FinishNotice(rows: waiting)
    }
}

public struct FinishNotice: Equatable, Sendable {
    public let rows: [DownloadRow]

    public init(rows: [DownloadRow]) {
        self.rows = rows
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

/// What Settings › General's "Then" does after a single download finishes.
public enum ThenAction: String, CaseIterable, Sendable {
    case nothing
    case showInFinder
    case open

    /// A saved choice, with anything unknown read as doing nothing.
    public init(saved: String) {
        self = ThenAction(rawValue: saved) ?? .nothing
    }

    public var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .showInFinder: "Show in Finder"
        case .open: "Open the file"
        }
    }
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
