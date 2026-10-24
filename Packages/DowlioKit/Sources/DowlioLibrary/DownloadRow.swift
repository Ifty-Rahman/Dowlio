import DowlioCore
import Foundation

/// One download as the library list shows it.
public struct DownloadRow: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case queued
        case downloading
        case retrying(attempt: Int, nextTry: Date)
        case paused
        case failed(DownloadError)
        case completed
    }

    public var id: DownloadID
    public var state: State
    public var fileName: String
    public var sourceURL: URL
    public var host: String?
    public var folder: URL
    public var category: FileCategory?
    public var receivedBytes: Int64
    /// `nil` while the size is unknown.
    public var totalBytes: Int64?
    public var segments: [SegmentProgress]
    public var activeConnections: Int
    public var bytesPerSecond: Int64
    public var timeRemaining: TimeInterval?
    public var isNotSecure: Bool
    public var canResume: Bool
    public var addedAt: Date
    public var completedAt: Date?
    /// A Completed download whose file is no longer where Dowlio put it.
    public var isFileMissing: Bool
    /// Completed without moving the file in, because a file with its name existed and the policy
    /// was Skip.
    public var wasSkipped: Bool

    public init(
        id: DownloadID,
        state: State,
        fileName: String,
        sourceURL: URL,
        host: String?,
        folder: URL,
        category: FileCategory?,
        receivedBytes: Int64,
        totalBytes: Int64?,
        segments: [SegmentProgress],
        activeConnections: Int,
        bytesPerSecond: Int64,
        timeRemaining: TimeInterval?,
        isNotSecure: Bool,
        canResume: Bool,
        addedAt: Date,
        completedAt: Date?,
        isFileMissing: Bool,
        wasSkipped: Bool
    ) {
        self.id = id
        self.state = state
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.host = host
        self.folder = folder
        self.category = category
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.segments = segments
        self.activeConnections = activeConnections
        self.bytesPerSecond = bytesPerSecond
        self.timeRemaining = timeRemaining
        self.isNotSecure = isNotSecure
        self.canResume = canResume
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.isFileMissing = isFileMissing
        self.wasSkipped = wasSkipped
    }

    /// How far the download is, from 0 to 1, or `nil` while the size is unknown.
    public var fractionDone: Double? {
        guard let totalBytes else { return nil }
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(Double(receivedBytes) / Double(totalBytes), 1)
    }

    public var canPause: Bool {
        switch state {
        case .downloading, .retrying, .queued: true
        case .paused, .failed, .completed: false
        }
    }

    public var canCancel: Bool { state != .completed }

    /// Cancel and Remove from List would delete bytes downloaded so far, so they ask first.
    public var hasBytesAtStake: Bool { state != .completed && receivedBytes > 0 }

    /// The server can't resume, so pausing throws away the bytes so far and asks first.
    public var pauseStartsOver: Bool { canPause && !canResume && receivedBytes > 0 }

    /// The extension in capitals, for the file-type badge. Empty when the name has none.
    public var badge: String {
        (fileName as NSString).pathExtension.uppercased()
    }

    public var finishedFile: URL? {
        guard state == .completed, !isFileMissing else { return nil }
        return folder.appending(path: fileName)
    }

    public var stateWord: String {
        switch state {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .retrying: "Retrying"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }

    /// "2.05 GB of 3.21 GB · 8 connections" while downloading, the size once Completed, the reason
    /// and next step once Failed.
    public var detailLine: String {
        switch state {
        case .completed:
            if isFileMissing { return "File not found" }
            return ByteText.string(totalBytes ?? receivedBytes)
        case .failed(let error):
            let failure = FailureText(error)
            return "\(failure.reason) · \(failure.nextStep)"
        case .downloading:
            let connections = activeConnections == 1 ? "1 connection" : "\(activeConnections) connections"
            return activeConnections > 0 ? "\(progressText) · \(connections)" : progressText
        case .queued, .paused, .retrying:
            return progressText
        }
    }

    /// "12.4 MB/s" while bytes arrive.
    public var speedText: String? {
        guard state == .downloading, bytesPerSecond > 0 else { return nil }
        return "\(ByteText.string(bytesPerSecond))/s"
    }

    /// "3 min left" while the size and speed are known.
    public var timeLeftText: String? {
        guard state == .downloading, let timeRemaining else { return nil }
        return "\(DurationText.string(timeRemaining)) left"
    }

    /// Never empty, so a row is as tall when it appears as it is later.
    private var progressText: String {
        if let totalBytes { return "\(ByteText.string(receivedBytes)) of \(ByteText.string(totalBytes))" }
        if receivedBytes > 0 { return ByteText.string(receivedBytes) }
        return switch state {
        case .queued: "Waiting for a free slot"
        case .paused: "Not started"
        case .retrying: "Waiting to try again"
        case .downloading, .failed, .completed: "Starting…"
        }
    }
}

/// A Failed download's reason and its one next step.
public struct FailureText: Equatable, Sendable {
    public var reason: String
    public var nextStep: String

    public init(_ error: DownloadError) {
        switch error {
        case .linkExpired: (reason, nextStep) = ("Link expired", "Copy a fresh link from the site and add it again")
        case .needsSignIn: (reason, nextStep) = ("Needs sign-in", "This site only gives the file to signed-in visitors")
        case .forbidden: (reason, nextStep) = ("Refused", "The server won't give this file")
        case .notFound: (reason, nextStep) = ("Not found", "The link may have been removed")
        case .network: (reason, nextStep) = ("Connection lost", "Check your network, then Retry")
        case .tooManyRetries: (reason, nextStep) = ("Kept failing", "Retry continues from where it stopped")
        case .serverChangedFile: (reason, nextStep) = ("The file changed on the server", "Retry starts it again")
        case .notEnoughSpace: (reason, nextStep) = ("Not enough space", "Free up space, then Retry")
        case .destinationNotWritable: (reason, nextStep) = ("Can't save to this folder", "Fix its permissions, then Retry")
        case .incompleteFile: (reason, nextStep) = ("Incomplete file", "Retry fetches the missing part")
        }
    }
}

/// Sizes in decimal units, as Finder shows them: "512 bytes", "3.15 MB", "41.9 MB", "205 GB".
public enum ByteText {
    public static func string(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 9.995 ? 2 : value < 99.95 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[unit])
    }
}

/// Time left, rounded up so it never promises less than it takes: "45 s", "3 min", "1 h 5 min".
public enum DurationText {
    public static func string(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        if total < 60 { return "\(total) s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
