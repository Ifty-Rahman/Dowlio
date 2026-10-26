import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

struct SentPageDraftTests {
    private let page = SentPage(
        url: URL(string: "https://www.example.com/watch?v=1")!, title: "Holiday clip", browser: "Arc",
        cookies: [Cookie(name: "session", value: "abc")], userAgent: "Mozilla/5.0 Arc"
    )
    private let clip = Candidate(
        label: "Holiday clip",
        duration: 61,
        versions: [Version(source: .file(URL(string: "https://cdn.example.com/clip.mp4")!), contentType: "video/mp4", totalBytes: 38_200_000)]
    )

    @Test func aSentPageLooksThenShowsItsOneVideoThenStarts() {
        var draft = SentPageDraft(page: page)
        #expect(draft.phase == .looking)
        #expect(draft.host == "example.com")

        _ = draft.update(.looking([Candidate(label: "Holiday clip", versions: [])]))
        #expect(draft.phase == .looking)

        _ = draft.update(.found([clip]))
        #expect(draft.phase == .oneVideo(clip))

        let id = DownloadID()
        draft.started(id)
        #expect(draft.phase == .started(id))
    }

    @Test func aVersionRowSaysItsTypeAndSize() {
        #expect(SentPageDraft.summary(of: clip.versions[0]) == "MP4 · 38.2 MB")
        #expect(SentPageDraft.summary(of: Version(source: .file(URL(string: "https://a.example/b.m4a")!))) == "M4A")
        #expect(SentPageDraft.durationText(61) == "1:01")
        #expect(SentPageDraft.durationText(3725) == "1:02:05")
    }

    @Test func aVersionDownloadsWithThePagesCookiesAndAgentAndSaysWhereItCameFrom() {
        let draft = SentPageDraft(page: page)

        let download = draft.download(clip.versions[0])

        #expect(download.source == .file(URL(string: "https://cdn.example.com/clip.mp4")!))
        #expect(download.options.cookies == [Cookie(name: "session", value: "abc")])
        #expect(download.options.userAgent == "Mozilla/5.0 Arc")
        #expect(download.options.referrer == URL(string: "https://www.example.com/watch?v=1"))
        #expect(download.origin == DownloadOrigin(kind: .sent, browser: "Arc"))
    }

    @Test func theFirstVersionIsChosenUntilAnotherIsPicked() {
        var draft = SentPageDraft(page: page)
        let ogg = Version(source: .file(URL(string: "https://cdn.example.com/clip.ogg")!), contentType: "video/ogg", totalBytes: 600)
        var both = clip
        both.versions.append(ogg)
        _ = draft.update(.found([both]))

        #expect(draft.chosenVersion == clip.versions[0])
        draft.pick(ogg)
        #expect(draft.chosenVersion == ogg)
    }

    @Test func aPageWithSeveralVideosListsThemAndOneCanBeChosen() {
        var draft = SentPageDraft(page: page)
        var other = clip
        other.label = "Second clip"

        _ = draft.update(.found([clip, other]))
        #expect(draft.phase == .several([clip, other]))

        draft.choose(other)
        #expect(draft.phase == .oneVideo(other))
        draft.backToList()
        #expect(draft.phase == .several([clip, other]))
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

    @Test func aChosenVersionDownloadsAsOneDownloadSentFromTheBrowser() async throws {
        let server = try await TestServer()
        let data = Data(repeating: 3, count: 64 * 1024)
        server.serve(TestServer.File(data: data, headers: ["Content-Type": "video/mp4"]), at: "/clip.mp4")
        let fixture = try await LibraryFixture()
        let draft = SentPageDraft(page: page)
        let download = draft.download(Version(source: .file(server.url(for: "/clip.mp4"))))

        let id = await fixture.library.add(download.source, destination: .folder(fixture.folder), options: download.options, origin: download.origin)
        let row = try await fixture.library.row(id) { $0.state == .completed }

        #expect(try await fixture.library.firstRows { _ in true }.count == 1)
        #expect(row.originText == "Sent from Arc")
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "clip.mp4")) == TestFiles.sha256(data))
    }
}
