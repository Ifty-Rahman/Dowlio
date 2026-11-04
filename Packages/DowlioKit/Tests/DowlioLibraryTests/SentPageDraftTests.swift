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

    @Test func eachVideoKeepsItsOwnVideoOrAudioChoice() {
        var draft = SentPageDraft(page: page)
        let withAudio = Candidate(label: "Talk", versions: [mp4, m4a])
        let other = Candidate(label: "Other talk", versions: [ogg, m4a])
        _ = draft.update(.found([withAudio, other]))

        draft.show(.audio)
        draft.select(1)

        #expect(draft.showing == .video)
        #expect(draft.chosenVersion == ogg)
        #expect(draft.chosenVersion(of: 0) == m4a)
        draft.select(0)
        #expect(draft.showing == .audio)
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

    @Test func noVideoIsIncludedUntilChosenWhenAPageHasSeveral() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([clip, second]))

        #expect(draft.downloads.isEmpty)
        #expect(!draft.isIncluded(0))
        #expect(!draft.isIncluded(1))
    }

    @Test func aPagesOnlyVideoStartsUnticked() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([clip]))

        #expect(draft.downloads.isEmpty)
        #expect(!draft.isIncluded(0))
    }

    @Test func chosenVideosDownloadEachOnesChoiceUntilTakenOut() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([clip, second]))
        draft.pick(ogg)
        draft.include(0, true)
        draft.include(1, true)

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
        #expect(MediaText.title(of: Version(source: .file(URL(string: "https://a.example/b")!), contentType: "audio/mpeg")) == "Audio")
        #expect(MediaText.detail(of: Version(source: .file(URL(string: "https://a.example/b")!), contentType: "audio/mpeg")) == "MPEG")
        #expect(MediaText.size(of: ogg.withoutSize) == nil)
        #expect(MediaText.duration(61) == "1:01")
        #expect(MediaText.duration(3725) == "1:02:05")
    }

    @Test func anAudioRowNamesItsTypeAndCodec() {
        let audio = Version(source: .file(URL(string: "https://cdn.example.com/talk.m4a")!), contentType: "audio/mp4", totalBytes: 3_420_000, codecs: "AAC")

        #expect([MediaText.title(of: audio), MediaText.detail(of: audio), MediaText.size(of: audio)] == ["Audio", "M4A · AAC", "3.42 MB"])
    }

    @Test func aRowWhoseFileWillBeWebMSaysWebM() throws {
        let clip = URL(string: "https://cdn.example.com/clip.webm")!
        let media = try MediaSource(
            tracks: [MediaTrack(kind: .video, fragments: [MediaFragment(url: clip)]), MediaTrack(kind: .audio, fragments: [MediaFragment(url: clip)])],
            container: .webm
        )
        let video = Version(source: .media(media), height: 2160, codecs: "VP9 + Opus")

        #expect(MediaText.detail(of: video) == "WebM · VP9 + Opus")
        #expect(MediaText.fileExtension(of: video) == "webm")
    }

    @Test func anExtractedAudioRowSaysSoAndShowsTheVideosSize() throws {
        let video = Version(source: .file(URL(string: "https://cdn.example.com/clip.mp4")!), contentType: "video/mp4", totalBytes: 38_200_000, codecs: "H.264 + AAC")
        let audio = try #require(Version.extractedAudio(of: video))

        #expect([MediaText.title(of: audio), MediaText.detail(of: audio), MediaText.size(of: audio)] == ["Audio", "M4A · AAC · extracted after download", "38.2 MB"])
        #expect(MediaText.isAudio(audio))
    }

    @Test func theExtractedAudioIsNamedAsAnM4A() throws {
        let video = Version(source: .file(URL(string: "https://cdn.example.com/clip.mp4")!), contentType: "video/mp4", totalBytes: 100)
        let audio = try #require(Version.extractedAudio(of: video))

        #expect(MediaNaming.fileName(label: "Holiday clip", version: audio) { _ in false } == "Holiday clip.m4a")
    }

    @Test func aFileWhoseAddressNamesNoMediaTypeTakesItsExtensionFromItsContentType() {
        let bare = Version(source: .file(URL(string: "https://cdn.example.com/stream/abc123?token=1")!), contentType: "video/mp4; charset=binary")
        let odd = Version(source: .file(URL(string: "https://cdn.example.com/get.php")!), contentType: "audio/mpeg")
        let plain = Version(source: .file(URL(string: "https://cdn.example.com/clip.webm")!), contentType: "video/mp4")
        let unknown = Version(source: .file(URL(string: "https://cdn.example.com/stream/abc123")!))

        #expect(MediaText.fileExtension(of: bare) == "mp4")
        #expect(MediaText.fileExtension(of: odd) == "mp3")
        #expect(MediaText.fileExtension(of: plain) == "webm")
        #expect(MediaText.fileExtension(of: unknown) == "")
        #expect(MediaNaming.fileName(label: "Clip | Example.tv", version: bare) { _ in false } == "Clip | Example.tv.mp4")
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
