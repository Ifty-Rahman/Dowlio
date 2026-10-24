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
        #expect(LibraryView(rows: rows, selection: .filter(filter), search: "").rows.map(\.fileName) == names)
    }

    @Test func theSidebarCountsEveryFilter() {
        let counts = LibraryView(rows: rows, selection: .filter(.all), search: "").counts
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
        #expect(LibraryView(rows: rows, selection: .filter(.all), search: search).rows.count == count)
    }

    @Test func searchCombinesWithTheFilter() {
        #expect(LibraryView(rows: rows, selection: .filter(.completed), search: "files.example").rows.map(\.fileName) == ["Résumé.docx"])
        #expect(LibraryView(rows: rows, selection: .filter(.paused), search: "files.example").rows.isEmpty)
    }

    @Test func theToolbarSummaryCountsTheShownItemsAndAddsUpEverySpeed() {
        #expect(LibraryView(rows: rows, selection: .filter(.all), search: "").summary == "7 downloads · 5.50 MB/s")
        #expect(LibraryView(rows: rows, selection: .filter(.completed), search: "").summary == "1 download · 5.50 MB/s")
        #expect(LibraryView(rows: [row("a.zip", host: nil, state: .paused)], selection: .filter(.all), search: "").summary == "1 download")
        #expect(LibraryView(rows: [], selection: .filter(.all), search: "").summary == "0 downloads")
    }

    @Test func pauseAllAndResumeAllAreOffWithNothingToDo() {
        let view = LibraryView(rows: rows, selection: .filter(.all), search: "")
        #expect(view.canPauseAll)
        #expect(view.canResumeAll)
        #expect(view.canClearCompleted)

        let failedOnly = LibraryView(rows: [row("gone.dmg", host: nil, state: .failed(.notFound))], selection: .filter(.all), search: "")
        #expect(!failedOnly.canPauseAll)
        #expect(!failedOnly.canResumeAll)
        #expect(!failedOnly.canClearCompleted)
    }

    @Test func aCategoryKeepsOnlyItsFilesAndCountsThem() {
        let categorised = [
            row("a.mp4", host: nil, state: .completed, category: .video),
            row("b.mkv", host: nil, state: .downloading, category: .video),
            row("c.pdf", host: nil, state: .paused, category: .documents),
            row("d.dat", host: nil, state: .completed, category: nil),
        ]
        let video = LibraryView(rows: categorised, selection: .category(.video), search: "")

        #expect(video.rows.map(\.fileName) == ["a.mp4", "b.mkv"])
        #expect(video.categoryCounts == [.video: 2, .audio: 0, .documents: 1, .archives: 0, .appsAndDiskImages: 0])
        #expect(LibraryView(rows: categorised, selection: .category(.audio), search: "").rows.isEmpty)
        #expect(LibraryView(rows: categorised, selection: .filter(.all), search: "").rows.count == 4)
    }

    @Test(arguments: [
        (LibrarySelection.filter(.all), "All Downloads"),
        (.filter(.failed), "Failed"),
        (.category(.appsAndDiskImages), "Apps & Disk Images"),
    ])
    func aSidebarChoiceIsSavedAsTextAndComesBackTheSame(selection: LibrarySelection, title: String) {
        #expect(LibrarySelection(rawValue: selection.rawValue) == selection)
        #expect(selection.title == title)
    }

    @Test func anUnknownSavedChoiceIsNotAChoice() {
        #expect(LibrarySelection(rawValue: "nonsense") == nil)
    }

    @Test func freeSpaceReadsLikeFinder() {
        #expect(FreeSpaceText.string(162_120_000_000) == "162 GB free")
        #expect(FreeSpaceText.string(9_400_000_000) == "9.40 GB free")
    }
}

private func row(
    _ name: String, host: String?, state: DownloadRow.State, speed: Int64 = 0, category: FileCategory? = nil
) -> DownloadRow {
    DownloadRow(
        id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
        host: host, folder: URL(filePath: "/tmp"), category: category, receivedBytes: 0, totalBytes: nil,
        segments: [], activeConnections: 0, bytesPerSecond: speed, timeRemaining: nil, isNotSecure: false,
        canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
    )
}
