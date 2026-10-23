import Foundation

/// Identifies one download, in the sense of `GLOSSARY.md`.
public struct DownloadID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Where a download is in its life. The interface shows `probing` and `finalizing` as Downloading.
public enum DownloadState: Equatable, Sendable {
    case probing
    case downloading
    case finalizing
    case completed
    case failed(DownloadError)
    /// The user cancelled the download. Its partial file is gone and the engine forgets it.
    case cancelled
    /// Waiting before trying a failed connection again. `attempt` counts the failures in a row,
    /// from 1. `nextTry` is when the next try starts. With several connections waiting, it shows
    /// the highest attempt and the earliest next try.
    case retrying(attempt: Int, nextTry: Date)

    /// No further snapshots follow a terminal state. Failed isn't terminal, because Retry
    /// continues a failed download (`GLOSSARY.md`), so its snapshot stream stays open.
    public var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

/// Why a download failed. Each case maps to one sentence of user copy in the interface.
public enum DownloadError: Error, Equatable, Sendable {
    case destinationNotWritable
    /// The server's range reply didn't match what Dowlio asked for. Ticket 05 falls back to one
    /// connection instead of failing.
    case rangeNotSupported
    /// The server sent fewer bytes than the file's size, so the file isn't complete.
    case incompleteFile
    case network(String)
    /// The destination volume can't hold the whole file.
    case notEnoughSpace
    /// The server wants a signed-in visitor (401).
    case needsSignIn
    /// The server refuses to give the file (403).
    case forbidden
    /// The server has no such file (404 or 410).
    case notFound
    /// One segment failed 5 times in a row. The partial file stays, so Retry continues it.
    case tooManyRetries
}

/// How a download should run. Each ticket adds the options it needs (spec, engine interface).
public struct RequestOptions: Equatable, Sendable {
    /// Connections per download, 1 to 16. Values outside that range are clamped.
    public var connections: Int = 8
    public var openExtraConnections: OpenExtraConnections = .afterFirstConnectionStarts

    public init() {}

    /// What happens when a file with the finished file's name already exists.
    public var nameConflictPolicy: NameConflictPolicy = .keepBoth
}

/// What to do when the destination already has a file with the finished file's name.
public enum NameConflictPolicy: Equatable, Sendable {
    /// Save the new file as "name 2.ext", "name 3.ext" and so on.
    case keepBoth
    /// Overwrite the existing file. The interface confirms this first.
    case replace
    /// Keep the existing file. The download completes without moving the new file in.
    case skip
}

/// When a download opens its connections after the first one.
public enum OpenExtraConnections: Equatable, Sendable {
    /// After the first connection starts receiving data, so a broken link costs one request.
    case afterFirstConnectionStarts
    case allAtOnce
}

/// One segment's progress, for the segmented bar.
public struct SegmentProgress: Equatable, Sendable {
    /// The segment's first byte.
    public var start: Int64
    /// The segment's last byte, inclusive.
    public var end: Int64
    public var receivedBytes: Int64
    /// Whether a connection is fetching this segment now.
    public var isActive: Bool

    public init(start: Int64, end: Int64, receivedBytes: Int64 = 0, isActive: Bool = false) {
        self.start = start
        self.end = end
        self.receivedBytes = receivedBytes
        self.isActive = isActive
    }
}

/// What the engine reports about one download.
public struct DownloadSnapshot: Equatable, Sendable {
    public var id: DownloadID
    public var state: DownloadState
    /// The name the finished file has, or will have.
    public var fileName: String
    public var destinationFolder: URL
    public var receivedBytes: Int64
    /// `nil` while the size is unknown.
    public var totalBytes: Int64?
    /// One entry per segment, in file order. Empty while the size is unknown.
    public var segments: [SegmentProgress] = []
    public var activeConnections: Int = 0
    /// Speed smoothed over the last 5 seconds.
    public var bytesPerSecond: Int64 = 0
    /// Seconds left at the current speed. `nil` while the size or the speed is unknown.
    public var timeRemaining: TimeInterval?
    /// The download uses plain HTTP, so its bytes travel unencrypted (ADR 0003).
    public var isNotSecure: Bool

    public init(
        id: DownloadID,
        state: DownloadState,
        fileName: String,
        destinationFolder: URL,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        isNotSecure: Bool = false
    ) {
        self.id = id
        self.state = state
        self.fileName = fileName
        self.destinationFolder = destinationFolder
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.isNotSecure = isNotSecure
    }
}
