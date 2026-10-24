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
        ([0.0], 1, false),
        ([0, 2], 1, false),
        ([0, 4.9], 1, false),
        ([0, 6], 2, false),
        ([0, 3, 6, 9], 1, false),
        ([0, 3, 9], 2, false),
    ] as [([TimeInterval], Int, Bool)])
    func finishesWithinFiveSecondsOfEachOtherShareANotice(offsets: [TimeInterval], notices: Int, unused: Bool) {
        var grouper = FinishGrouper()
        var posted: [FinishNotice] = []
        for (index, offset) in offsets.enumerated() {
            let now = start.addingTimeInterval(offset)
            if let due = grouper.takeDue(at: now) { posted.append(due) }
            grouper.add(row("file\(index).zip", .completed), at: now)
        }
        if let last = grouper.takeDue(at: start.addingTimeInterval((offsets.last ?? 0) + FinishGrouper.window)) { posted.append(last) }
        #expect(posted.count == notices)
        #expect(posted.reduce(0) { $0 + $1.rows.count } == offsets.count)
    }

    @Test func nothingIsDueBeforeTheWindowCloses() {
        var grouper = FinishGrouper()
        grouper.add(row("a.zip", .completed), at: start)
        #expect(grouper.takeDue(at: start.addingTimeInterval(4)) == nil)
        #expect(grouper.dueDate == start.addingTimeInterval(FinishGrouper.window))
        #expect(grouper.takeDue(at: start.addingTimeInterval(5))?.rows.count == 1)
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
