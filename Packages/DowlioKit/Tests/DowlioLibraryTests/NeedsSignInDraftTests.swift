import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct NeedsSignInDraftTests {
    private let url = URL(string: "https://members.example/watch")!

    @Test func aPageSentThroughDowlioConnectAsksTheUserToSignInAndSendAgain() {
        var draft = SentPageDraft(page: SentPage(url: url, browser: "Arc", throughDowlioConnect: true))

        _ = draft.update(.needsSignIn)

        #expect(draft.phase == .needsSignIn)
        #expect(draft.signIn == [
            "This site only shows this video to signed-in visitors. Sign in to it in your browser, then send the page again.",
        ])
    }

    @Test func aPageSentWithoutDowlioConnectAlsoSuggestsInstallingIt() {
        var draft = SentPageDraft(page: SentPage(url: url))

        _ = draft.update(.needsSignIn)

        #expect(draft.signIn == [
            "This site only shows this video to signed-in visitors. Sign in to it in your browser, then send the page again.",
            "Install Dowlio Connect so Dowlio can use your sign-in.",
        ])
    }

    @Test func nothingCanBeDownloadedFromAPageThatNeedsSignIn() {
        var draft = SentPageDraft(page: SentPage(url: url))

        _ = draft.update(.needsSignIn)

        #expect(draft.downloads.isEmpty)
    }
}

struct NeedsPasswordDraftTests {
    @Test func aVideoThatNeedsAPasswordSaysHowToGetIt() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://vimeo.com/11111111")!))

        _ = draft.update(.found([Candidate(label: "Private Video", versions: [], restriction: .needsPassword)]))

        #expect(draft.phase == .needsSignIn)
        #expect(draft.signIn == ["This video needs a password. Open it in your browser, enter the password, then send the page."])
    }
}
