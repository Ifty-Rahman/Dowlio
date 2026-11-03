import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct BlockedDraftTests {
    private let url = URL(string: "https://www.example.com/watch?v=1")!

    @Test func aBlockedPageShowsTheBlockedStateWithNoVideos() {
        var draft = SentPageDraft(page: SentPage(url: url))

        _ = draft.update(.blocked)

        #expect(draft.phase == .blocked)
        #expect(draft.candidates.isEmpty)
    }

    @Test func theBlockedTextNamesTheSiteAndAsksForTheBrowser() {
        var draft = SentPageDraft(page: SentPage(url: url))
        _ = draft.update(.blocked)

        #expect(draft.blocked == [
            "example.com wants to check you're a person. Open the page in your browser, then send it to Dowlio.",
            "Install Dowlio Connect so Dowlio can use your sign-in.",
        ])
    }

    @Test func aPageSentThroughDowlioConnectDoesNotAskToInstallIt() {
        var draft = SentPageDraft(page: SentPage(url: url, browser: "Arc", throughDowlioConnect: true))
        _ = draft.update(.blocked)

        #expect(draft.blocked.count == 1)
    }
}
