import DowlioCore
import Foundation

/// What can be done to the selected downloads, which of them each action touches, and how the
/// menus, confirmations and inspector word it.
public struct SelectionSummary: Equatable, Sendable {
    public let rows: [DownloadRow]

    public init(rows: [DownloadRow]) {
        self.rows = rows
    }

    public var pausable: [DownloadRow] { rows.filter(\.canPause) }
    public var resumable: [DownloadRow] { rows.filter { $0.state == .paused } }
    public var retryable: [DownloadRow] { rows.filter { if case .failed = $0.state { true } else { false } } }
    public var cancellable: [DownloadRow] { rows.filter(\.canCancel) }
    public var finishedFiles: [URL] { rows.compactMap(\.finishedFile) }

    public var bytesAtStake: Int64 {
        rows.filter(\.hasBytesAtStake).reduce(0) { $0 + $1.receivedBytes }
    }

    public var removeAsksFirst: Bool { bytesAtStake > 0 }

    public var pauseTitle: String { Self.menuTitle("Pause", count: pausable.count) }
    public var resumeTitle: String { Self.menuTitle("Resume", count: resumable.count) }
    public var retryTitle: String { Self.menuTitle("Retry", count: retryable.count) }

    public var cancelTitle: String {
        cancellable.count > 1 ? "Cancel \(cancellable.count) Downloads…" : "Cancel Download…"
    }

    public var copyLinksTitle: String {
        rows.count > 1 ? "Copy \(rows.count) Links" : "Copy Link"
    }

    public var removeTitle: String {
        let base = rows.count > 1 ? "Remove \(rows.count) from List" : "Remove from List"
        return removeAsksFirst ? base + "…" : base
    }

    public var cancelQuestion: String {
        cancellable.count == 1 ? "Cancel this download?" : "Cancel \(cancellable.count) downloads?"
    }

    public var removeQuestion: String {
        rows.count == 1 ? "Remove “\(rows[0].fileName)” from the list?" : "Remove \(rows.count) downloads from the list?"
    }

    public var trashQuestion: String {
        let files = rows.filter { $0.finishedFile != nil }
        return files.count == 1 ? "Move “\(files[0].fileName)” to the Trash?" : "Move \(files.count) files to the Trash?"
    }

    /// The bytes Cancel or Remove would delete, or `nil` when none would be lost.
    public var lossWarning: String? {
        bytesAtStake > 0 ? "The \(ByteText.string(bytesAtStake)) downloaded so far will be deleted." : nil
    }

    public var title: String { "\(rows.count) selected" }

    public var sizeText: String {
        let received = rows.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let totals = rows.compactMap(\.totalBytes)
        guard totals.count == rows.count else { return ByteText.string(received) }
        return "\(ByteText.string(received)) of \(ByteText.string(totals.reduce(0, +)))"
    }

    public var speedText: String? {
        let speed = rows.reduce(Int64(0)) { $0 + ($1.speedText == nil ? 0 : $1.bytesPerSecond) }
        return speed > 0 ? "\(ByteText.string(speed))/s" : nil
    }

    public var linksText: String {
        rows.map(\.sourceURL.absoluteString).joined(separator: "\n")
    }

    private static func menuTitle(_ verb: String, count: Int) -> String {
        count > 1 ? "\(verb) \(count) Downloads" : verb
    }
}
