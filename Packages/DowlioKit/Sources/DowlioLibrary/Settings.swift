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
    /// A connection that finishes early takes over half of the slowest segment's work. Off unless
    /// the user turns it on.
    public var takesOverSlowSegments = false
    public var videoQualityCap: Int?
    public var prefersH264 = true

    public var qualityPreference: QualityPreference {
        QualityPreference(quality: videoQualityCap.map(VideoQuality.upTo) ?? .best, prefersH264: prefersH264)
    }

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
        options.allowsWorkStealing = takesOverSlowSegments
        return options
    }

    public func destination(in folder: URL) -> Destination {
        sortsIntoCategoryFolders ? .categoryFolders(under: folder) : .folder(folder)
    }
}

/// Where Dowlio shows itself. It's always in the menu bar or the Dock, or both, and always in the
/// menu bar when it starts there.
public struct Presence: Equatable, Sendable {
    public enum Switch: Sendable {
        case menuBar
        case dock
        case startsInMenuBar
    }

    public var menuBar: Bool
    public var dock: Bool
    /// Every launch opens no window, only the menu bar icon.
    public var startsInMenuBar: Bool

    public init(menuBar: Bool, dock: Bool, startsInMenuBar: Bool = false) {
        self.menuBar = menuBar
        self.dock = dock
        self.startsInMenuBar = startsInMenuBar
    }

    /// Show in menu bar is greyed out while Dowlio starts there, since the icon is the only way in.
    public var canChangeMenuBar: Bool { !startsInMenuBar }

    /// With Show in Dock off, the Dock icon still shows while a window is open, as macOS does for
    /// menu bar apps, and goes with the last window.
    public func showsDockIcon(windowOpen: Bool) -> Bool {
        dock || windowOpen
    }

    public func opensWindowAtLaunch(launchedAtLogin: Bool) -> Bool {
        !startsInMenuBar && !launchedAtLogin
    }

    /// Turning off the one place Dowlio still shows turns the other back on, with a note saying so.
    public func setting(_ which: Switch, to isOn: Bool) -> (presence: Presence, note: String?) {
        var next = self
        switch which {
        case .menuBar:
            guard canChangeMenuBar else { return (self, nil) }
            next.menuBar = isOn
        case .dock:
            next.dock = isOn
        case .startsInMenuBar:
            next.startsInMenuBar = isOn
            if isOn { next.menuBar = true }
        }
        guard !next.menuBar, !next.dock else { return (next, nil) }
        if which == .menuBar {
            next.dock = true
            return (next, "Dowlio stays in the Dock, so you can always reach it.")
        }
        next.menuBar = true
        return (next, "Dowlio stays in the menu bar, so you can always reach it.")
    }
}

/// How long a link sent to the menu bar waits there, with what came with it, before Dowlio
/// forgets it. Quitting Dowlio forgets it sooner, since it's never saved.
public enum SentLinkWait: Int, CaseIterable, Sendable {
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case sixHours = 360
    case twelveHours = 720
    case oneDay = 1440

    public static let standard = SentLinkWait.thirtyMinutes

    public var duration: Duration { .seconds(rawValue * 60) }

    public var title: String {
        rawValue < 60 ? "\(rawValue) minutes" : rawValue == 60 ? "1 hour" : "\(rawValue / 60) hours"
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
