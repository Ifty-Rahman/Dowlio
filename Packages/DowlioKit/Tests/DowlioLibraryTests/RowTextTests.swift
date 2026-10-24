import DowlioCore
@testable import DowlioLibrary
import Foundation
import Testing

struct RowTextTests {
    @Test(arguments: [
        (DownloadError.linkExpired, "Link expired · Copy a fresh link from the site and add it again"),
        (.needsSignIn, "Needs sign-in · This site only gives the file to signed-in visitors"),
        (.forbidden, "Refused · The server won't give this file"),
        (.notFound, "Not found · The link may have been removed"),
        (.network(NetworkFailure(code: .networkConnectionLost, message: "")), "Connection lost · Check your network, then Retry"),
        (.tooManyRetries, "Kept failing · Retry continues from where it stopped"),
        (.serverChangedFile, "The file changed on the server · Retry starts it again"),
        (.notEnoughSpace, "Not enough space · Free up space, then Retry"),
        (.destinationNotWritable, "Can't save to this folder · Fix its permissions, then Retry"),
        (.incompleteFile, "Incomplete file · Retry fetches the missing part"),
    ])
    func aFailedRowSaysTheReasonAndOneNextStep(error: DownloadError, line: String) {
        #expect(Self.row(state: .failed(error)).detailLine == line)
        #expect(Self.row(state: .failed(error)).stateWord == "Failed")
    }

    @Test(arguments: [
        (Int64(0), "0 bytes"),
        (1, "1 byte"),
        (999, "999 bytes"),
        (1000, "1.00 KB"),
        (524_288, "524 KB"),
        (3_145_728, "3.15 MB"),
        (41_900_000, "41.9 MB"),
        (2_050_000_000, "2.05 GB"),
        (205_000_000_000, "205 GB"),
        (999_600_000, "1.00 GB"),
    ])
    func sizesUseDecimalUnitsAsFinderDoes(bytes: Int64, text: String) {
        #expect(ByteText.string(bytes) == text)
    }

    @Test(arguments: [
        (0.0, "0 s"),
        (44.2, "45 s"),
        (60, "1 min"),
        (61, "2 min"),
        (3599, "1 h"),
        (3600, "1 h"),
        (3900, "1 h 5 min"),
    ])
    func timeLeftRoundsUp(seconds: TimeInterval, text: String) {
        #expect(DurationText.string(seconds) == text)
    }

    @Test func aDownloadingRowShowsProgressConnectionsSpeedAndTimeLeft() {
        var row = Self.row(state: .downloading)
        row.receivedBytes = 2_050_000_000
        row.totalBytes = 3_210_000_000
        row.activeConnections = 8
        row.bytesPerSecond = 12_400_000
        row.timeRemaining = 94

        #expect(row.detailLine == "2.05 GB of 3.21 GB · 8 connections")
        #expect(row.speedText == "12.4 MB/s")
        #expect(row.timeLeftText == "2 min left")
    }

    @Test func aRowOfUnknownSizeShowsOnlyTheBytesSoFar() {
        var row = Self.row(state: .downloading)
        row.receivedBytes = 3_145_728
        row.activeConnections = 1

        #expect(row.detailLine == "3.15 MB · 1 connection")
        #expect(row.timeLeftText == nil)
    }

    @Test func aPausedRowShowsNoSpeed() {
        var row = Self.row(state: .paused)
        row.receivedBytes = 1000
        row.totalBytes = 2000
        row.bytesPerSecond = 500

        #expect(row.detailLine == "1.00 KB of 2.00 KB")
        #expect(row.speedText == nil)
        #expect(row.stateWord == "Paused")
    }

    @Test func queuedAndRetryingRowsHaveTheirOwnWords() {
        #expect(Self.row(state: .queued).stateWord == "Queued")
        #expect(Self.row(state: .retrying(attempt: 2, nextTry: Date())).stateWord == "Retrying")
    }

    @Test func theFractionDoneComesFromTheBytesAndIsUnknownWithoutASize() {
        var row = Self.row(state: .downloading)
        #expect(row.fractionDone == nil)
        row.receivedBytes = 250
        row.totalBytes = 1000
        #expect(row.fractionDone == 0.25)
        row.totalBytes = 0
        #expect(row.fractionDone == 0)
        row.state = .completed
        #expect(row.fractionDone == 1)
    }

    @Test(arguments: [
        (DownloadRow.State.downloading, Int64(500), false, true),
        (.downloading, 500, true, false),
        (.downloading, 0, false, false),
        (.retrying(attempt: 1, nextTry: Date()), 500, false, true),
        (.paused, 500, false, false),
    ])
    func pausingAsksFirstOnlyWhenItWouldStartTheFileOver(state: DownloadRow.State, received: Int64, canResume: Bool, asks: Bool) {
        var row = Self.row(state: state)
        row.receivedBytes = received
        row.canResume = canResume
        #expect(row.pauseStartsOver == asks)
    }

    @Test(arguments: [
        (DownloadRow.State.downloading, Int64(500), true),
        (.paused, 500, true),
        (.failed(.tooManyRetries), 500, true),
        (.paused, 0, false),
        (.queued, 0, false),
        (.completed, 500, false),
    ])
    func cancelAndRemoveAskFirstOnlyWhenBytesWouldBeLost(state: DownloadRow.State, received: Int64, asks: Bool) {
        var row = Self.row(state: state)
        row.receivedBytes = received
        #expect(row.hasBytesAtStake == asks)
    }

    @Test func onlyRunningDownloadsPauseAndOnlyUnfinishedOnesCancel() {
        #expect(Self.row(state: .downloading).canPause)
        #expect(Self.row(state: .queued).canPause)
        #expect(!Self.row(state: .paused).canPause)
        #expect(Self.row(state: .paused).canCancel)
        #expect(!Self.row(state: .completed).canCancel)
    }

    /// Every row keeps the same lines from the moment it appears, so its height never changes
    /// while the list lays it out.
    @Test(arguments: [
        (DownloadRow.State.downloading, "Starting…"),
        (.queued, "Waiting for a free slot"),
        (.paused, "Not started"),
        (.retrying(attempt: 1, nextTry: Date()), "Waiting to try again"),
    ])
    func aRowWithNothingYetStillHasADetailLine(state: DownloadRow.State, line: String) {
        #expect(Self.row(state: state).detailLine == line)
    }

    @Test func theInspectorSaysHowManySegmentsStealingAdded() {
        var row = Self.row(state: .downloading)
        let planned = [SegmentProgress(start: 0, end: 99), SegmentProgress(start: 100, end: 199)]
        row.segments = planned
        row.displaySegments = planned
        #expect(row.segmentCountText == "2")

        row.segments = planned + [SegmentProgress(start: 150, end: 199)]
        #expect(row.segmentCountText == "2 planned, 1 added")

        row.segments = planned + [SegmentProgress(start: 150, end: 199), SegmentProgress(start: 75, end: 99)]
        #expect(row.segmentCountText == "2 planned, 2 added")
    }

    @Test(arguments: [
        (TimeInterval(42), "42 s"),
        (200, "3 min 20 s"),
        (3600, "1 h"),
        (3900, "1 h 5 min"),
        (0.4, "Less than a second"),
    ])
    func aCompletedRowSaysHowLongItTook(seconds: TimeInterval, text: String) {
        var row = Self.row(state: .completed)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        row.startedAt = start
        row.completedAt = start.addingTimeInterval(seconds)
        #expect(row.timeTakenText == text)
    }

    @Test func onlyACompletedRowWithBothTimesSaysHowLongItTook() {
        var row = Self.row(state: .downloading)
        row.startedAt = Date()
        #expect(row.timeTakenText == nil)
        row.state = .completed
        #expect(row.timeTakenText == nil)
    }

    private static func row(state: DownloadRow.State) -> DownloadRow {
        DownloadRow(
            id: DownloadID(), state: state, fileName: "file.zip", sourceURL: URL(string: "https://example.com/file.zip")!,
            host: "example.com", folder: URL(filePath: "/tmp"), category: .archives, receivedBytes: 0, totalBytes: nil,
            segments: [], activeConnections: 0, bytesPerSecond: 0, timeRemaining: nil, isNotSecure: false,
            canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
        )
    }
}
