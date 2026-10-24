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

    /// The window opens at the first finish, so a steady trickle of finishes can't hold a notice
    /// back for ever.
    @Test(arguments: [
        ([0.0], 1),
        ([0, 2], 1),
        ([0, 4.9], 1),
        ([0, 6], 2),
        ([0, 3, 6, 9], 2),
        ([0, 1, 2, 3, 4, 5.5, 6.5, 7.5, 8.5, 9.5, 11], 3),
    ] as [([TimeInterval], Int)])
    func finishesWithinFiveSecondsOfTheFirstShareANotice(offsets: [TimeInterval], notices: Int) {
        var grouper = FinishGrouper()
        var posted: [FinishNotice] = []
        for (index, offset) in offsets.enumerated() {
            let now = start.addingTimeInterval(offset)
            if let due = grouper.takeDue(at: now) { posted.append(due) }
            grouper.add(row("file\(index).zip", .completed), at: now)
        }
        if let due = grouper.dueDate, let last = grouper.takeDue(at: due) { posted.append(last) }
        #expect(posted.count == notices)
        #expect(posted.reduce(0) { $0 + $1.rows.count } == offsets.count)
    }

    @Test func nothingIsDueBeforeTheWindowClosesAndALaterFinishDoesntMoveIt() {
        var grouper = FinishGrouper()
        grouper.add(row("a.zip", .completed), at: start)
        grouper.add(row("b.zip", .completed), at: start.addingTimeInterval(3))
        #expect(grouper.takeDue(at: start.addingTimeInterval(4)) == nil)
        #expect(grouper.dueDate == start.addingTimeInterval(FinishGrouper.window))
        #expect(grouper.takeDue(at: start.addingTimeInterval(5))?.rows.count == 2)
        #expect(grouper.dueDate == nil)
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

    @Test func onlyASingleFinishHasAFileForItsActions() {
        #expect(FinishNotice(rows: [row("a.zip", .completed)]).singleFile?.lastPathComponent == "a.zip")
        #expect(FinishNotice(rows: [row("a.zip", .completed), row("b.zip", .completed)]).singleFile == nil)
    }

    @Test(arguments: [
        ("showInFinder", ThenAction.showInFinder), ("open", .open), ("nothing", .nothing), ("", .nothing), ("nonsense", .nothing),
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
