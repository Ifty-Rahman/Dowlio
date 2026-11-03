import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PageWindowReadingTests {
    private func analyzer(_ lookAgain: LookAgain? = nil) -> PageAnalyzer {
        let engine = DownloadEngine(configuration: .fast)
        return PageAnalyzer(lookAgain: lookAgain) { url, options in try await engine.inspect(url, options: options) }
    }

    @Test func whatAWindowSawIsReadTheWayLookAgainReadsAPlayedPage() async throws {
        let site = try await Site()
        site.serve(video: 4000, at: "/seen/clip.mp4")
        let played = PlayedPage(title: "Seen clip", media: [WatchedRequest(url: site.url("/seen/clip.mp4"), kind: .file)])

        let found = await analyzer().reading(played, of: SentPage(url: site.url("/watch")))

        #expect(found.withoutExtractedAudio == .found([Candidate(
            label: "Seen clip",
            versions: [Version(source: .file(site.url("/seen/clip.mp4")), contentType: "video/mp4", totalBytes: 4000)]
        )]))
    }

    @Test func readingNeverPlaysThePageAgain() async throws {
        let site = try await Site()
        let played = PlayedPage(title: "Nothing")

        let found = await analyzer { _ in
            Issue.record("played the page")
            return PlayedPage()
        }.reading(played, of: SentPage(url: site.url("/watch")))

        #expect(found == .found([]))
    }

    @Test func aWindowStuckOnACheckForAPersonIsBlocked() async throws {
        let site = try await Site()
        let played = PlayedPage(title: "Just a moment...", html: "<html><head><title>Just a moment...</title></head></html>")

        #expect(await analyzer().reading(played, of: SentPage(url: site.url("/watch"))) == .blocked)
    }

    @Test func theWindowsCookiesGoWithTheFileChecks() async throws {
        let site = try await Site()
        var file = TestServer.File(data: Data(repeating: 7, count: 900), headers: ["Content-Type": "video/mp4"])
        file.requiredCookie = "session=abc"
        site.server.serve(file, at: "/seen/members.mp4")
        let played = PlayedPage(title: "Members", media: [WatchedRequest(url: site.url("/seen/members.mp4"), kind: .file)])

        let found = await analyzer().reading(played, of: SentPage(url: site.url("/watch"), cookies: [Cookie(name: "session", value: "abc")]))

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).map(\.totalBytes) == [900])
    }
}
