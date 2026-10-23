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

    /// No further snapshots follow a terminal state. Failed isn't terminal, because Retry
    /// continues a failed download (`GLOSSARY.md`), so its snapshot stream stays open.
    public var isTerminal: Bool {
        self == .completed
    }
}

/// Why a download failed. Each case maps to one sentence of user copy in the interface.
public enum DownloadError: Error, Equatable, Sendable {
    /// A file with the finished file's name already exists. Ticket 09 replaces this with the
    /// name conflict policy.
    case fileExists
    case destinationNotWritable
    /// The server's range reply didn't match what Dowlio asked for. Ticket 05 falls back to one
    /// connection instead of failing.
    case rangeNotSupported
    /// The server sent fewer bytes than the file's size, so the file isn't complete.
    case incompleteFile
    /// The server answered with a status Dowlio doesn't handle yet. Ticket 04 replaces this with
    /// not found, forbidden, needs sign-in and retries.
    case unexpectedStatus(Int)
    case network(String)
}

/// How a download should run. Each ticket adds the options it needs (spec, engine interface).
public struct RequestOptions: Equatable, Sendable {
    public init() {}
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

    public init(
        id: DownloadID,
        state: DownloadState,
        fileName: String,
        destinationFolder: URL,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) {
        self.id = id
        self.state = state
        self.fileName = fileName
        self.destinationFolder = destinationFolder
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}
