import DowlioCore
import DowlioLibrary
import Foundation
import Testing

/// Which finishes Dowlio tells the user about, and how finishes close together are grouped.
struct FinishedNoticeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyDownloadsThatFinishWhileDowlioWatchesCount() {
        let old = row("old.zip", .completed)
        var running = row("new.zip", .downloading)
        var watcher = FinishWatcher()

        #expect(watcher.newlyFinished(in: [old, running]).isEmpty)
        running.state = .completed
        #expect(watcher.newlyFinished(in: [old, running]).map(\.fileName) == ["new.zip"])
        #expect(watcher.newlyFinished(in: [old, running]).isEmpty)
    }

    @Test func aDownloadAddedAlreadyFinishedDoesntCount() {
        var watcher = FinishWatcher()
        _ = watcher.newlyFinished(in: [])
        #expect(watcher.newlyFinished(in: [row("instant.zip", .downloading)]).isEmpty)
        #expect(watcher.newlyFinished(in: [row("other.zip", .completed)]).isEmpty)
    }

    @Test(arguments: [
        ([0.0], [1]),
        ([0, 2], [1, 2]),
        ([0, 4.9], [1, 2]),
        ([0, 6], [1, 1]),
        ([0, 3, 6, 9], [1, 2, 1, 2]),
    ] as [([TimeInterval], [Int])])
    func eachNoticeShowsAtOnceAndOnesWithinFiveSecondsOfTheFirstJoinIt(offsets: [TimeInterval], sizes: [Int]) {
        var grouper = NoticeGrouper()
        let shown = offsets.enumerated().map { index, offset in
            grouper.add(row("file\(index).zip", .completed), at: start.addingTimeInterval(offset))
        }
        #expect(shown.map(\.rows.count) == sizes)
        for (previous, next) in zip(shown, shown.dropFirst()) {
            #expect((previous.group == next.group) == (next.rows.count > 1))
        }
    }

    @Test func onlyDownloadsThatNewlyNeedAttentionCount() {
        let old = row("old.zip", .failed(.notFound))
        var running = row("new.zip", .downloading)
        var watcher = ProblemWatcher()

        #expect(watcher.newProblems(in: [old, running]).isEmpty)
        running.state = .failed(.network(NetworkFailure(code: .timedOut, message: "")))
        #expect(watcher.newProblems(in: [old, running]).map(\.fileName) == ["new.zip"])
        #expect(watcher.newProblems(in: [old, running]).isEmpty)
        running.state = .retrying(attempt: 1, nextTry: start)
        #expect(watcher.newProblems(in: [old, running]).isEmpty)
        running.state = .failed(.tooManyRetries)
        #expect(watcher.newProblems(in: [old, running]).map(\.fileName) == ["new.zip"])
    }

    @Test func aDownloadAddedAlreadyFailedCounts() {
        var watcher = ProblemWatcher()
        _ = watcher.newProblems(in: [])
        #expect(watcher.newProblems(in: [row("gone.zip", .failed(.notFound))]).map(\.fileName) == ["gone.zip"])
    }

    @Test func aPausedDownloadThatLostItsCookiesCounts() {
        var paused = row("video.mp4", .downloading)
        var watcher = ProblemWatcher()
        _ = watcher.newProblems(in: [paused])
        paused.state = .paused
        paused.lostCookies = true
        let notice = ProblemNotice(rows: watcher.newProblems(in: [paused]))
        #expect(notice.title == "Download can't resume")
        #expect(notice.retryable == nil)
    }

    @Test func oneFailureNamesItsFileReasonAndNextStep() {
        let failed = row("Report.pdf", .failed(.notFound))
        let notice = ProblemNotice(rows: [failed])
        #expect(notice.title == "Download failed")
        #expect(notice.body == "Report.pdf\nNot found. The link may have been removed.")
        #expect(notice.retryable == failed.id)
    }

    @Test func severalProblemsCollapse() {
        let failed = ProblemNotice(rows: [row("a.zip", .failed(.notFound)), row("b.zip", .failed(.forbidden))])
        #expect(failed.title == "2 downloads failed")
        #expect(failed.body == "a.zip and b.zip")
        #expect(failed.retryable == nil)
        var paused = row("c.zip", .paused)
        paused.lostCookies = true
        #expect(ProblemNotice(rows: [row("a.zip", .failed(.notFound)), paused]).title == "2 downloads need attention")
    }

    @Test func oneFinishNamesItsFileAndOffersTheThenAction() {
        let notice = FinishNotice(rows: [row("Report.pdf", .completed)])
        #expect(notice.title == "Download finished")
        #expect(notice.body == "Report.pdf")
        #expect(notice.runsThenAction)
    }

    @Test func severalFinishesCollapseAndSkipTheThenAction() {
        let notice = FinishNotice(rows: [row("a.zip", .completed), row("b.zip", .completed), row("c.zip", .completed)])
        #expect(notice.title == "3 downloads finished")
        #expect(notice.body == "a.zip, b.zip and c.zip")
        #expect(!notice.runsThenAction)
    }

    @Test func clickingAFinishNoticeOpensDowlioUnlessTheUserChoseOtherwise() {
        #expect(NotificationClick(saved: "") == .openDowlio)
        #expect(NotificationClick(saved: "something old") == .openDowlio)
        #expect(NotificationClick(saved: "openFile") == .openFile)
        #expect(NotificationClick.allCases.map(\.title) == ["Open Dowlio", "Show in Finder", "Open the file"])
    }

    @Test func clickingANoticeForSeveralFilesAlwaysOpensDowlio() {
        let one = FinishNotice(rows: [row("a.zip", .completed)])
        let several = FinishNotice(rows: [row("a.zip", .completed), row("b.zip", .completed)])

        #expect(NotificationClick.showInFinder.target(for: one.singleFile) == .showInFinder(one.singleFile!))
        #expect(NotificationClick.openFile.target(for: one.singleFile) == .open(one.singleFile!))
        #expect(NotificationClick.openFile.target(for: several.singleFile) == .dowlio)
        #expect(NotificationClick.openDowlio.target(for: one.singleFile) == .dowlio)
    }

    @Test func anUpdateNoticeSaysANewVersionIsAvailable() {
        let notice = UpdateNotice(version: "0.4.2")
        #expect(notice.title == "A new version of Dowlio is available")
        #expect(notice.body == "Dowlio 0.4.2 is ready to install. Click to see what's new.")
        #expect(notice.menuBarLine == "Dowlio 0.4.2 is available")
        #expect(notice.menuTitle == "Update to Dowlio 0.4.2…")
        #expect(notice.dockBadge == "1")
    }

    @Test func onlyASingleFinishHasAFileForItsActions() {
        #expect(FinishNotice(rows: [row("a.zip", .completed)]).singleFile?.lastPathComponent == "a.zip")
        #expect(FinishNotice(rows: [row("a.zip", .completed), row("b.zip", .completed)]).singleFile == nil)
    }

    @Test(arguments: [
        ("showInFinder", ThenAction.showInFinder), ("open", .nothing), ("nothing", .nothing), ("", .nothing), ("nonsense", .nothing),
    ])
    func aSavedThenChoiceReadsBackAndAnythingElseDoesNothing(saved: String, action: ThenAction) {
        #expect(ThenAction(saved: saved) == action)
    }

    @Test func manyFinishesNameTheFirstFewOnly() {
        let rows = (1...6).map { row("f\($0).zip", .completed) }
        #expect(FinishNotice(rows: rows).body == "f1.zip, f2.zip, f3.zip and 3 more")
    }

    private func row(_ name: String, _ state: DownloadRow.State) -> DownloadRow {
        DownloadRow(
            id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
            host: "example.com", folder: URL(filePath: "/tmp"), category: nil, receivedBytes: 0, totalBytes: nil,
            segments: [], activeConnections: 0, bytesPerSecond: 0, timeRemaining: nil, isNotSecure: false,
            canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
        )
    }
}
