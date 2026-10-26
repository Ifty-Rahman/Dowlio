import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct RestrictedVideoTests {
    private let page = SentPage(url: URL(string: "https://films.example/watch")!)
    private let locked = Candidate(label: "Film", versions: [], restriction: .protected)
    private let live = Candidate(label: "Live now", versions: [], restriction: .live)
    private let trailer = Candidate(label: "Trailer", versions: [Version(source: .file(URL(string: "https://films.example/t.mp4")!), contentType: "video/mp4")])

    @Test func aPageWhoseOnlyVideoIsProtectedSaysSoAndOffersNoDownload() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.found([locked]))

        #expect(draft.phase == .restricted(.protected))
        #expect(draft.restrictionLine == "This video is protected and can't be downloaded")
        #expect(draft.downloads.isEmpty)
        #expect(draft.chosenVersion == nil)
    }

    @Test func aLiveBroadcastSaysItIsntSupportedYet() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.found([live]))

        #expect(draft.phase == .restricted(.live))
        #expect(draft.restrictionLine == "Live stream, not supported yet")
        #expect(draft.downloads.isEmpty)
    }

    @Test func otherVideosStayListedAndOnlyTheyDownload() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.found([trailer, locked]))

        #expect(draft.phase == .found)
        #expect(draft.restrictionLine == nil)
        #expect(draft.downloads.map(\.candidate) == [trailer])
        draft.select(1)
        #expect(draft.restrictionLine == "This video is protected and can't be downloaded")
        #expect(draft.downloads.map(\.candidate) == [trailer])
    }
}
