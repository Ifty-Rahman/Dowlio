import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YTDLPProblemTests {
    private func problem(_ failure: YTDLPFailure, on link: String = "https://www.youtube.com/watch?v=2Vv-BfVoq4g") -> ProblemText? {
        var draft = SentPageDraft(page: SentPage(url: URL(string: link)!))
        _ = draft.update(.ytdlpFailed(failure))
        return draft.problem
    }

    @Test func eachFailureHasOneSentenceAndANextStep() {
        #expect(problem(.unsupportedSite) == ProblemText(sentence: "yt-dlp doesn't support this site.", action: .lookAgain))
        #expect(problem(.private) == ProblemText(sentence: "This video is private.", action: nil))
        #expect(problem(.geoBlocked) == ProblemText(sentence: "This video isn't available in your country.", action: nil))
        #expect(problem(.extractorBroken) == ProblemText(sentence: "yt-dlp can't read this site right now. An update may fix it.", action: .checkForUpdate))
        #expect(problem(.network) == ProblemText(sentence: "Dowlio couldn't reach the site.", action: .tryAgain))
        #expect(problem(.live) == ProblemText(sentence: "This video is live. Download it after the stream ends.", action: nil))
    }

    @Test func rateLimitingNamesYouTubeOnlyOnYouTube() {
        #expect(problem(.rateLimited) == ProblemText(sentence: "YouTube is limiting requests. Try again in a few minutes.", action: .tryAgain))
        #expect(problem(.rateLimited, on: "https://www.ted.com/talks/a")?.sentence == "The site is limiting requests. Try again in a few minutes.")
    }

    @Test func aFailedDraftShowsNoCandidates() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.youtube.com/watch?v=x")!))

        _ = draft.update(.ytdlpFailed(.private))

        #expect(draft.phase == .ytdlpFailed(.private))
        #expect(draft.candidates.isEmpty)
    }

    @Test func aYouTubeDownloadWithTheBrowsersSignInNeverStoresItsCookies() async throws {
        let fixture = try await LibraryFixture()
        let media = try MediaSource(
            tracks: [MediaTrack(kind: .audio, fragments: [MediaFragment(url: URL(string: "http://127.0.0.1:9/videoplayback?itag=140")!, bytes: 0...99)])],
            container: .m4a,
            renewal: MediaRenewal(pageURL: URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!, formatIDs: ["140"])
        )
        var options = RequestOptions()
        options.cookies = [Cookie(name: "SID", value: "secret-session-value", domain: ".youtube.com")]

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options, startImmediately: false)
        _ = try await fixture.library.row(id) { _ in true }

        let database = try Data(contentsOf: fixture.databaseURL)
        let journal = (try? Data(contentsOf: URL(fileURLWithPath: fixture.databaseURL.path + "-wal"))) ?? Data()
        #expect(database.range(of: Data("secret-session-value".utf8)) == nil)
        #expect(journal.range(of: Data("secret-session-value".utf8)) == nil)
    }
}
