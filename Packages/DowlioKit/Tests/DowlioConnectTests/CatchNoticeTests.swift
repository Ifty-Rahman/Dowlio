import DowlioConnect
import DowlioCore
import Foundation
import Testing

struct CatchNoticeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func caught(_ name: String, bytes: Int64? = nil) -> CaughtDownload {
        CaughtDownload(id: DownloadID(), link: URL(string: "https://example.com/\(name)")!, fileName: name, totalBytes: bytes)
    }

    @Test func aSingleCatchSaysItWasAddedAndOffersTheBrowserBack() {
        var grouper = CatchGrouper()

        let notice = grouper.add(caught("blender.dmg", bytes: 312_000_000), at: start)

        #expect(notice.title == "Added to Dowlio")
        #expect(notice.detail == "blender.dmg · 312 MB")
        #expect(notice.offersDownloadInBrowser)
        #expect(notice.showTitle == "Show")
    }

    @Test func aCatchOfUnknownSizeShowsJustItsName() {
        var grouper = CatchGrouper()
        #expect(grouper.add(caught("live.ts"), at: start).detail == "live.ts")
    }

    @Test func catchesCloseTogetherCollapseIntoOneNoticeThatOnlyOffersShow() {
        var grouper = CatchGrouper()

        let first = grouper.add(caught("a.zip"), at: start)
        _ = grouper.add(caught("b.zip"), at: start.addingTimeInterval(0.5))
        let third = grouper.add(caught("c.zip"), at: start.addingTimeInterval(1.5))

        #expect(third.id == first.id)
        #expect(third.title == "3 downloads caught")
        #expect(third.detail == "a.zip, b.zip and c.zip")
        #expect(third.downloads.count == 3)
        #expect(!third.offersDownloadInBrowser)
        #expect(third.showTitle == "Show in Dowlio")
    }

    @Test(arguments: [
        ([0.0], 1),
        ([0, 1], 1),
        ([0, 1.9], 1),
        ([0, 2.1], 2),
        ([0, 1, 2.5, 3.5], 2),
        ([0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5], 3),
    ] as [([TimeInterval], Int)])
    func catchesWithinTwoSecondsOfTheFirstShareANotice(offsets: [TimeInterval], notices: Int) {
        var grouper = CatchGrouper()
        var shown: [CatchNotice] = []
        for (index, offset) in offsets.enumerated() {
            let notice = grouper.add(caught("file\(index).zip"), at: start.addingTimeInterval(offset))
            shown.removeAll { $0.id == notice.id }
            shown.append(notice)
        }
        #expect(shown.count == notices)
        #expect(shown.reduce(0) { $0 + $1.downloads.count } == offsets.count)
    }
}
