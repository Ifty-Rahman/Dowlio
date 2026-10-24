import DowlioCore
import Foundation

/// The Downloads and Connections settings, and what they make a new download do. A change
/// applies to downloads added or restored afterwards. Running ones keep what they started with.
public struct DownloadSettings: Equatable, Sendable {
    public var folder: URL
    public var sortsIntoCategoryFolders = false
    public var nameConflictPolicy = NameConflictPolicy.keepBoth
    public var connections = 8
    public var downloadsAtOnce = 3
    public var openExtraConnections = OpenExtraConnections.afterFirstConnectionStarts
    public var retries = 5

    public init(folder: URL) {
        self.folder = folder
    }

    /// The engine counts failed attempts, and the setting counts tries after the first failure.
    public var maximumFailures: Int {
        min(max(retries, 0), 10) + 1
    }

    /// The options a new download gets. `connections` is the New Download sheet's own choice,
    /// when it made one.
    public func options(connections chosen: Int?) -> RequestOptions {
        var options = RequestOptions()
        options.connections = min(max(chosen ?? connections, 1), 16)
        options.maximumFailures = maximumFailures
        options.openExtraConnections = openExtraConnections
        options.nameConflictPolicy = nameConflictPolicy
        return options
    }

    public func destination(in folder: URL) -> Destination {
        sortsIntoCategoryFolders ? .categoryFolders(under: folder) : .folder(folder)
    }
}

/// Where Dowlio shows itself. It's always in the menu bar or the Dock, or both.
public struct Presence: Equatable, Sendable {
    public enum Switch: Sendable {
        case menuBar
        case dock
    }

    public var menuBar: Bool
    public var dock: Bool

    public init(menuBar: Bool, dock: Bool) {
        self.menuBar = menuBar
        self.dock = dock
    }

    /// Turning off the one place Dowlio still shows turns the other back on, with a note saying so.
    public func setting(_ which: Switch, to isOn: Bool) -> (presence: Presence, note: String?) {
        var next = self
        switch which {
        case .menuBar: next.menuBar = isOn
        case .dock: next.dock = isOn
        }
        guard !next.menuBar, !next.dock else { return (next, nil) }
        switch which {
        case .menuBar:
            next.dock = true
            return (next, "Dowlio stays in the Dock, so you can always reach it.")
        case .dock:
            next.menuBar = true
            return (next, "Dowlio stays in the menu bar, so you can always reach it.")
        }
    }
}

/// The question before quitting stops downloads. `nil` when nothing would stop.
public struct QuitGuard: Equatable, Sendable {
    public let count: Int

    public init?(rows: [DownloadRow]) {
        let stopping = rows.count { LibraryFilter.downloading.includes($0) || $0.state == .queued }
        guard stopping > 0 else { return nil }
        count = stopping
    }

    public var title: String {
        count == 1 ? "Stop 1 download and quit?" : "Stop \(count) downloads and quit?"
    }

    public var message: String { "They can resume next time." }
}
