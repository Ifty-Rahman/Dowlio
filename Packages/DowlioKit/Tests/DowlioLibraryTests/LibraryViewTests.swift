import DowlioCore
@testable import DowlioLibrary
import Foundation
import Testing

/// The sidebar's filters and counts, search, and the toolbar's summary.
struct LibraryViewTests {
    private let rows: [DownloadRow] = [
        row("ubuntu.iso", host: "releases.ubuntu.com", state: .downloading, speed: 4_000_000),
        row("Report.pdf", host: "files.example.com", state: .retrying(attempt: 1, nextTry: Date()), speed: 0),
        row("song.mp3", host: "cdn.example.com", state: .paused),
        row("later.zip", host: "mirror.org", state: .queued),
        row("gone.dmg", host: "apps.example.com", state: .failed(.notFound)),
        row("Résumé.docx", host: "files.example.com", state: .completed),
        row("movie.mp4", host: "media.example.net", state: .downloading, speed: 1_500_000),
    ]

    @Test(arguments: [
        (LibraryFilter.all, ["ubuntu.iso", "Report.pdf", "song.mp3", "later.zip", "gone.dmg", "Résumé.docx", "movie.mp4"]),
        (.downloading, ["ubuntu.iso", "Report.pdf", "movie.mp4"]),
        (.paused, ["song.mp3"]),
        (.queued, ["later.zip"]),
        (.failed, ["gone.dmg"]),
        (.completed, ["Résumé.docx"]),
    ])
    func eachFilterKeepsItsStatesInOrder(filter: LibraryFilter, names: [String]) {
        #expect(LibraryView(rows: rows, filter: filter, search: "").rows.map(\.fileName) == names)
    }

    @Test func theSidebarCountsEveryFilter() {
        let counts = LibraryView(rows: rows, filter: .all, search: "").counts
        #expect(counts == [.all: 7, .downloading: 3, .paused: 1, .queued: 1, .failed: 1, .completed: 1])
    }

    @Test(arguments: [
        ("", 7),
        ("report", 1),
        ("resume", 1),
        ("files.example", 2),
        ("EXAMPLE", 5),
        ("nothing like this", 0),
        ("  ubuntu  ", 1),
    ])
    func searchMatchesTheNameOrTheHostIgnoringCaseAndAccents(search: String, count: Int) {
        #expect(LibraryView(rows: rows, filter: .all, search: search).rows.count == count)
    }

    @Test func searchCombinesWithTheFilter() {
        #expect(LibraryView(rows: rows, filter: .completed, search: "files.example").rows.map(\.fileName) == ["Résumé.docx"])
        #expect(LibraryView(rows: rows, filter: .paused, search: "files.example").rows.isEmpty)
    }

    @Test func theToolbarSummaryCountsTheShownItemsAndAddsUpEverySpeed() {
        #expect(LibraryView(rows: rows, filter: .all, search: "").summary == "7 downloads · 5.50 MB/s")
        #expect(LibraryView(rows: rows, filter: .completed, search: "").summary == "1 download · 5.50 MB/s")
        #expect(LibraryView(rows: [row("a.zip", host: nil, state: .paused)], filter: .all, search: "").summary == "1 download")
        #expect(LibraryView(rows: [], filter: .all, search: "").summary == "0 downloads")
    }

    @Test func pauseAllAndResumeAllAreOffWithNothingToDo() {
        let view = LibraryView(rows: rows, filter: .all, search: "")
        #expect(view.canPauseAll)
        #expect(view.canResumeAll)
        #expect(view.canClearCompleted)

        let failedOnly = LibraryView(rows: [row("gone.dmg", host: nil, state: .failed(.notFound))], filter: .all, search: "")
        #expect(!failedOnly.canPauseAll)
        #expect(!failedOnly.canResumeAll)
        #expect(!failedOnly.canClearCompleted)
    }

    @Test func freeSpaceReadsLikeFinder() {
        #expect(FreeSpaceText.string(162_120_000_000) == "162 GB free")
        #expect(FreeSpaceText.string(9_400_000_000) == "9.40 GB free")
    }
}

private func row(_ name: String, host: String?, state: DownloadRow.State, speed: Int64 = 0) -> DownloadRow {
    DownloadRow(
        id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
        host: host, folder: URL(filePath: "/tmp"), category: nil, receivedBytes: 0, totalBytes: nil,
        segments: [], activeConnections: 0, bytesPerSecond: speed, timeRemaining: nil, isNotSecure: false,
        canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
    )
}
