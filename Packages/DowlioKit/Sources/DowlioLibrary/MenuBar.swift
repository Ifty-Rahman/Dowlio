import DowlioCore
import Foundation

/// What the menu bar icon and its popover show.
public struct MenuBarSummary: Equatable, Sendable {
    public static let listLimit = 5

    private let running: [DownloadRow]
    private let waiting: [DownloadRow]
    private let paused: [DownloadRow]

    public init(rows: [DownloadRow]) {
        running = rows.filter { LibraryFilter.downloading.includes($0) }
        waiting = rows.filter { $0.state == .queued }
        paused = rows.filter { $0.state == .paused }
    }

    public var status: String {
        var parts: [String] = []
        if !running.isEmpty { parts.append("\(running.count) downloading") }
        if !waiting.isEmpty { parts.append("\(waiting.count) queued") }
        return parts.isEmpty ? "Nothing downloading" : parts.joined(separator: " · ")
    }

    public var speedText: String? {
        let speed = running.reduce(Int64(0)) { $0 + ($1.speedText == nil ? 0 : $1.bytesPerSecond) }
        return speed > 0 ? "\(ByteText.string(speed))/s" : nil
    }

    /// Running, then Queued, then Paused, so a paused download can be resumed from here.
    public var active: [DownloadRow] {
        Array((running + waiting + paused).prefix(Self.listLimit))
    }

    public var moreActive: Int {
        max(running.count + waiting.count + paused.count - Self.listLimit, 0)
    }

    public var canPauseAll: Bool { !running.isEmpty || !waiting.isEmpty }

    /// How full the icon's ring is, or `nil` to hide it because nothing is downloading. Downloads
    /// of unknown size don't count; with only those, the ring is full.
    public var ringFraction: Double? {
        guard !running.isEmpty else { return nil }
        let sized = running.compactMap { row in row.totalBytes.map { (row.receivedBytes, $0) } }
        let total = sized.reduce(Int64(0)) { $0 + $1.1 }
        guard total > 0 else { return 1 }
        return min(Double(sized.reduce(Int64(0)) { $0 + $1.0 }) / Double(total), 1)
    }
}

/// How a link reaches Dowlio.
public enum NewLinkEntry: Sendable {
    case popoverAddLink
    case paste
    case drop
    case newDownloadCommand
}

/// Where a new link opens.
public enum NewLinkRoute: Equatable, Sendable {
    /// The small panel in the menu bar, without the main window.
    case quickAdd
    case sheet
    case openWindowThenSheet

    public init(entry: NewLinkEntry, windowIsOpen: Bool) {
        switch entry {
        case .popoverAddLink: self = .quickAdd
        case .paste, .drop: self = .sheet
        case .newDownloadCommand: self = windowIsOpen ? .sheet : .openWindowThenSheet
        }
    }
}

/// Report a Problem: a new GitHub issue that carries the versions and nothing about what the
/// user downloads.
public enum ProblemReport {
    public static func url(appVersion: String, macOSVersion: String) -> URL {
        var components = URLComponents(string: "https://github.com/Ifty-Rahman/Dowlio/issues/new")!
        let body = """
        ## What happened


        ## What you expected


        ---
        Dowlio \(appVersion) · macOS \(macOSVersion)
        """
        components.queryItems = [URLQueryItem(name: "title", value: ""), URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}
