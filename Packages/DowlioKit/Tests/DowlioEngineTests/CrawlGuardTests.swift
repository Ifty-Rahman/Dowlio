@testable import DowlioEngine
import Testing

struct CrawlGuardTests {
    private let began = ContinuousClock.now

    @Test func aPieceIsNeverCalledSlowDuringItsFirstSeconds() {
        #expect(!DownloadRun.isCrawling(written: 0, since: began, now: began + .seconds(10)))
    }

    @Test func aPieceBelowTheMinimumRateAfterTheGraceIsCrawling() {
        #expect(DownloadRun.isCrawling(written: 50_000, since: began, now: began + .seconds(30)))
    }

    @Test func aPieceAtAnOrdinaryRateIsNotCrawling() {
        #expect(!DownloadRun.isCrawling(written: 900_000, since: began, now: began + .seconds(30)))
    }
}
