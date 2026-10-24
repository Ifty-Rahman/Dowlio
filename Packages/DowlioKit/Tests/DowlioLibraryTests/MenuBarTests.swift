import DowlioCore
@testable import DowlioLibrary
import Foundation
import Testing

/// What the menu bar shows, where a new link goes, and what Report a Problem sends.
struct MenuBarTests {
    @Test func theSummarySaysWhatIsDownloadingAndWaiting() {
        let summary = MenuBarSummary(rows: [
            row("a.iso", .downloading, received: 250, total: 1000, speed: 2_000_000),
            row("b.iso", .retrying(attempt: 1, nextTry: Date()), received: 0, total: 1000),
            row("c.iso", .queued),
            row("d.iso", .paused),
            row("e.iso", .completed),
        ])

        #expect(summary.status == "2 downloading · 1 queued")
        #expect(summary.speedText == "2.00 MB/s")
        #expect(summary.active.map(\.fileName) == ["a.iso", "b.iso", "c.iso"])
        #expect(summary.ringFraction == 0.125)
    }

    @Test(arguments: [
        ([DownloadRow](), "Nothing downloading"),
        ([row("a.iso", .queued)], "1 queued"),
        ([row("a.iso", .downloading)], "1 downloading"),
        ([row("a.iso", .paused), row("b.iso", .completed)], "Nothing downloading"),
    ])
    func theStatusLineNamesOnlyWhatThereIs(rows: [DownloadRow], status: String) {
        #expect(MenuBarSummary(rows: rows).status == status)
    }

    @Test func theRingIsOffWhenNothingDownloadsAndFullWhenTheSizeIsUnknown() {
        #expect(MenuBarSummary(rows: [row("a.iso", .paused, received: 5, total: 10)]).ringFraction == nil)
        #expect(MenuBarSummary(rows: [row("a.iso", .downloading, received: 5, total: nil)]).ringFraction == 1)
    }

    @Test func thePopoverListsAtMostFiveActiveDownloads() {
        let rows = (0..<8).map { row("f\($0).iso", .downloading) }
        #expect(MenuBarSummary(rows: rows).active.count == 5)
        #expect(MenuBarSummary(rows: rows).moreActive == 3)
    }

    @Test(arguments: [
        (NewLinkEntry.popoverAddLink, true, NewLinkRoute.quickAdd),
        (.popoverAddLink, false, .quickAdd),
        (.paste, true, .sheet),
        (.drop, true, .sheet),
        (.newDownloadCommand, true, .sheet),
        (.newDownloadCommand, false, .openWindowThenSheet),
    ])
    func eachWayInLeadsToItsSurface(entry: NewLinkEntry, windowIsOpen: Bool, route: NewLinkRoute) {
        #expect(NewLinkRoute(entry: entry, windowIsOpen: windowIsOpen) == route)
    }

    @Test func aProblemReportCarriesOnlyTheVersions() throws {
        let url = ProblemReport.url(appVersion: "0.1.0 (1)", macOSVersion: "27.0.1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.host == "github.com")
        #expect(components.path == "/Ifty-Rahman/Dowlio/issues/new")
        #expect(items["body"]?.contains("Dowlio 0.1.0 (1)") == true)
        #expect(items["body"]?.contains("macOS 27.0.1") == true)
        #expect(items["body"]?.contains("## What happened") == true)
        #expect(Set(items.keys) == ["title", "body"])
    }
}

private func row(_ name: String, _ state: DownloadRow.State, received: Int64 = 0, total: Int64? = nil, speed: Int64 = 0) -> DownloadRow {
    DownloadRow(
        id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
        host: "example.com", folder: URL(filePath: "/tmp"), category: nil, receivedBytes: received, totalBytes: total,
        segments: [], activeConnections: 0, bytesPerSecond: speed, timeRemaining: nil, isNotSecure: false,
        canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
    )
}
