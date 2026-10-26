import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct NothingFoundTests {
    private let page = SentPage(url: URL(string: "https://missav.example/v/abc")!, browser: "Arc")
    private let clip = Candidate(label: "Clip", versions: [Version(source: .file(URL(string: "https://cdn.example/clip.mp4")!))])

    @Test func lookingSaysItIsPlayingThePageWhenTheQuickStepsFindNothing() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.playing)

        #expect(draft.phase == .playing)
        #expect(draft.lookingLine == "Playing the page to find the video")
    }

    @Test func lookingStartsByLookingAtThePage() {
        let draft = SentPageDraft(page: page)

        #expect(draft.phase == .looking)
        #expect(draft.lookingLine == "Looking at the page")
    }

    @Test func nothingFoundWithoutPlayingOffersLookAgainAndExplainsIt() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.found([]))

        #expect(draft.phase == .nothingFound)
        #expect(draft.nothingFound == NothingFoundText(
            title: "No video or audio found on this page",
            explanation: "Look Again opens the page in a hidden window for up to 10 seconds to catch its video.",
            action: "Look Again",
            note: nil
        ))
    }

    @Test func nothingFoundAfterPlayingByItselfSaysSoAndOffersTryAgain() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.playing)
        _ = draft.update(.found([]))

        #expect(draft.nothingFound == NothingFoundText(
            title: "No video or audio found on this page",
            explanation: "Dowlio played the page in a hidden window by itself, and no video loaded. Try Again plays it once more, for up to 10 seconds.",
            action: "Try Again",
            note: nil
        ))
    }

    @Test func aSecondEmptyResultSaysThePageMayHaveNoVideo() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.playing)
        _ = draft.update(.found([]))

        draft.lookAgain()
        #expect(draft.phase == .playing)
        _ = draft.update(.playing)
        _ = draft.update(.found([]))

        #expect(draft.nothingFound.action == "Try Again")
        #expect(draft.nothingFound.explanation == "Dowlio played the page in a hidden window, and no video loaded. Try Again plays it once more, for up to 10 seconds.")
        #expect(draft.nothingFound.note == "This page may not have a video, or its video is protected.")
    }

    @Test func lookingAgainCanFindTheVideo() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([]))

        draft.lookAgain()
        _ = draft.update(.playing)
        _ = draft.update(.found([clip]))

        #expect(draft.phase == .found)
        #expect(draft.candidates == [clip])
    }

    @Test func cancellingPlayingShowsNothingFoundWithLookAgain() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.playing)

        draft.cancelPlaying()

        #expect(draft.phase == .nothingFound)
        #expect(draft.nothingFound.action == "Look Again")
        #expect(draft.nothingFound.note == nil)
    }
}
