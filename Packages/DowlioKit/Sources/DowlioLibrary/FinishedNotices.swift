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

/// Holds finishes until five seconds pass without another, so finishes close together share one
/// notice.
public struct FinishGrouper: Sendable {
    public static let window: TimeInterval = 5

    private var waiting: [DownloadRow] = []
    private var lastFinish: Date?

    public init() {}

    public mutating func add(_ row: DownloadRow, at date: Date) {
        waiting.append(row)
        lastFinish = date
    }

    /// When the waiting finishes become due, or `nil` with none waiting.
    public var dueDate: Date? {
        lastFinish.map { $0.addingTimeInterval(Self.window) }
    }

    public mutating func takeDue(at now: Date) -> FinishNotice? {
        guard let dueDate, now >= dueDate, !waiting.isEmpty else { return nil }
        defer {
            waiting = []
            lastFinish = nil
        }
        return FinishNotice(rows: waiting)
    }
}

/// One notification for one or more finished downloads.
public struct FinishNotice: Equatable, Sendable {
    public let rows: [DownloadRow]

    public init(rows: [DownloadRow]) {
        self.rows = rows
    }

    public var title: String {
        rows.count == 1 ? "Download finished" : "\(rows.count) downloads finished"
    }

    /// The file name, or up to three names and how many more.
    public var body: String {
        let names = rows.map(\.fileName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }

    /// "Then" in Settings runs for a single finish only, so several never open a pile of files.
    public var runsThenAction: Bool { rows.count == 1 }
}
