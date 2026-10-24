import DowlioCore
import DowlioLibrary
import Foundation
import Testing

/// What can be done to several selected downloads at once, and how it reads.
struct SelectionSummaryTests {
    private let running = row("a.iso", .downloading, received: 1_000_000, total: 4_000_000, speed: 2_000_000)
    private let waiting = row("b.iso", .queued)
    private let paused = row("c.iso", .paused, received: 500_000, total: 1_000_000)
    private let failed = row("d.iso", .failed(.notFound), received: 200_000)
    private let done = row("e.pdf", .completed, received: 3_000_000, total: 3_000_000)

    @Test func eachActionCoversOnlyTheRowsItAppliesTo() {
        let summary = SelectionSummary(rows: [running, waiting, paused, failed, done])
        #expect(summary.pausable.map(\.fileName) == ["a.iso", "b.iso"])
        #expect(summary.resumable.map(\.fileName) == ["c.iso"])
        #expect(summary.retryable.map(\.fileName) == ["d.iso"])
        #expect(summary.cancellable.map(\.fileName) == ["a.iso", "b.iso", "c.iso", "d.iso"])
        #expect(summary.finishedFiles.map(\.lastPathComponent) == ["e.pdf"])
    }

    @Test(arguments: [
        (1, "Pause", "Resume", "Remove from List", "Cancel Download…", "Copy Link"),
        (3, "Pause 3 Downloads", "Resume 3 Downloads", "Remove 3 from List", "Cancel 3 Downloads…", "Copy 3 Links"),
    ])
    func menuItemsSayHowManyTheyActOn(count: Int, pause: String, resume: String, remove: String, cancel: String, copy: String) {
        let rows = (0..<count).map { _ in row("x.iso", .downloading) }
        let resumable = (0..<count).map { _ in row("x.iso", .paused) }
        #expect(SelectionSummary(rows: rows).pauseTitle == pause)
        #expect(SelectionSummary(rows: resumable).resumeTitle == resume)
        #expect(SelectionSummary(rows: rows).removeTitle == remove)
        #expect(SelectionSummary(rows: rows).cancelTitle == cancel)
        #expect(SelectionSummary(rows: rows).copyLinksTitle == copy)
    }

    @Test func removingAsksOnceWhenAnyBytesWouldBeLost() {
        let summary = SelectionSummary(rows: [running, paused, done])
        #expect(summary.bytesAtStake == 1_500_000)
        #expect(summary.removeAsksFirst)
        #expect(summary.removeTitle == "Remove 3 from List…")
        #expect(!SelectionSummary(rows: [done, waiting]).removeAsksFirst)
    }

    @Test func theConfirmationsCountTheDownloadsAndTheBytes() {
        let summary = SelectionSummary(rows: [running, paused])
        #expect(summary.cancelQuestion == "Cancel 2 downloads?")
        #expect(summary.removeQuestion == "Remove 2 downloads from the list?")
        #expect(summary.lossWarning == "The 1.50 MB downloaded so far will be deleted.")
        #expect(SelectionSummary(rows: [done, done]).trashQuestion == "Move 2 files to the Trash?")
        #expect(SelectionSummary(rows: [running]).cancelQuestion == "Cancel this download?")
    }

    @Test func theInspectorSumsUpSeveralDownloads() {
        let summary = SelectionSummary(rows: [running, paused, done])
        #expect(summary.title == "3 selected")
        #expect(summary.sizeText == "4.50 MB of 8.00 MB")
        #expect(summary.speedText == "2.00 MB/s")
    }

    @Test func aDownloadOfUnknownSizeLeavesOnlyTheBytesSoFar() {
        #expect(SelectionSummary(rows: [running, failed]).sizeText == "1.20 MB")
    }

    @Test func copyLinkCopiesEveryLinkOnItsOwnLine() {
        #expect(SelectionSummary(rows: [running, done]).linksText == "https://example.com/a.iso\nhttps://example.com/e.pdf")
    }
}

private func row(
    _ name: String, _ state: DownloadRow.State, received: Int64 = 0, total: Int64? = nil, speed: Int64 = 0
) -> DownloadRow {
    DownloadRow(
        id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
        host: "example.com", folder: URL(filePath: "/tmp/nonexistent-dowlio-test"), category: nil,
        receivedBytes: received, totalBytes: total, segments: [], activeConnections: 0, bytesPerSecond: speed,
        timeRemaining: nil, isNotSecure: false, canResume: true, addedAt: Date(), completedAt: nil,
        isFileMissing: false, wasSkipped: false
    )
}
