import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct SentPageDraftTests {
    private let page = SentPage(
        url: URL(string: "https://www.example.com/watch?v=1")!, title: "Holiday clip", browser: "Arc",
        cookies: [Cookie(name: "session", value: "abc")], userAgent: "Mozilla/5.0 Arc"
    )
    private let mp4 = Version(source: .file(URL(string: "https://cdn.example.com/clip.mp4")!), contentType: "video/mp4", totalBytes: 38_200_000)
    private let ogg = Version(source: .file(URL(string: "https://cdn.example.com/clip.ogg")!), contentType: "video/ogg", totalBytes: 600)
    private let m4a = Version(source: .file(URL(string: "https://cdn.example.com/talk.m4a")!), contentType: "audio/mp4", totalBytes: 900)
    private var clip: Candidate { Candidate(label: "Holiday clip", duration: 61, versions: [mp4, ogg]) }
    private var second: Candidate { Candidate(label: "Second: clip/2", versions: [ogg]) }

    @Test func aSentPageLooksThenFindsItsVideos() {
        var draft = SentPageDraft(page: page)
        #expect(draft.phase == .looking)
        #expect(draft.host == "example.com")

        _ = draft.update(.looking([Candidate(label: "Holiday clip", versions: [])]))
        #expect(draft.phase == .looking)

        _ = draft.update(.found([clip]))
        #expect(draft.phase == .found)
        #expect(draft.candidates == [clip])
        #expect(draft.selectedCandidate == clip)
    }

    @Test func aPageWithNoVideoSaysNothingWasFound() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.found([]))

        #expect(draft.phase == .nothingFound)
    }

    @Test func aLinkToAPlainFileIsHandedBackForTheFileCard() {
        var draft = SentPageDraft(page: page)

        #expect(draft.update(.plainFile(URL(string: "https://example.com/report.pdf")!)) == URL(string: "https://example.com/report.pdf"))
        #expect(draft.update(.found([clip])) == nil)
    }

    @Test func eachVideoKeepsItsOwnChosenVersionStartingWithTheFirst() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([clip, second]))

        #expect(draft.chosenVersion == mp4)
        draft.pick(ogg)
        draft.select(1)
        #expect(draft.selectedCandidate == second)
        #expect(draft.chosenVersion == ogg)
        draft.select(0)
        #expect(draft.chosenVersion == ogg)
    }

    @Test func everyVideoIsIncludedUntilTakenOutAndDownloadsTakeEachOnesChoice() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([clip, second]))
        draft.pick(ogg)

        #expect(draft.downloads.map(\.version) == [ogg, ogg])
        draft.include(0, false)
        #expect(draft.downloads.map(\.version) == [ogg])
        #expect(draft.downloads.map(\.candidate.label) == ["Second: clip/2"])
        #expect(!draft.isIncluded(0))
    }

    @Test func videoAndAudioVersionsAreListedApartWhenAVideoHasBoth() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([Candidate(label: "Talk", versions: [mp4, m4a])]))

        #expect(draft.hasVideoAndAudio)
        #expect(draft.versions(showing: .video) == [mp4])
        #expect(draft.versions(showing: .audio) == [m4a])
    }

    @Test func aFilesTypeDecidesVideoOrAudioBeforeItsExtension() {
        let bare = Version(source: .file(URL(string: "https://cdn.example.com/talk.ogg")!))

        #expect(MediaText.isAudio(bare))
        #expect(!MediaText.isAudio(ogg))
        #expect(MediaText.isAudio(m4a))
    }

    @Test func aVersionRowNamesItsTypeAndSize() {
        #expect(MediaText.title(of: mp4) == "MP4")
        #expect(MediaText.size(of: mp4) == "38.2 MB")
        #expect(MediaText.title(of: Version(source: .file(URL(string: "https://a.example/b")!), contentType: "audio/mpeg")) == "MPEG")
        #expect(MediaText.size(of: ogg.withoutSize) == nil)
        #expect(MediaText.duration(61) == "1:01")
        #expect(MediaText.duration(3725) == "1:02:05")
    }

    @Test func theSourceLineSaysWhichBrowserSentItAndWhetherItWasSignedIn() {
        #expect(SentPageDraft(page: page).sourceLine == "example.com · from Arc, signed in")
        #expect(SentPageDraft(page: SentPage(url: page.url, browser: "Dia")).sourceLine == "example.com · from Dia")
        #expect(SentPageDraft(page: SentPage(url: page.url)).sourceLine == "example.com")
    }

}

private extension Version {
    var withoutSize: Version { Version(source: source, contentType: contentType, totalBytes: nil) }
}
