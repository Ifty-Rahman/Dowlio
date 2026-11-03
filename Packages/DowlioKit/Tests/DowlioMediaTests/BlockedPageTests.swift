import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BlockedPageTests {
    private final class Plays: @unchecked Sendable {
        private let lock = NSLock()
        private var played = 0
        var count: Int { lock.withLock { played } }
        func record() { lock.withLock { played += 1 } }
    }

    private static let challenge = "<html><head><title>Just a moment...</title></head><body>Checking your browser before accessing the site.</body></html>"

    private func analyzer(
        cooldown: HostCooldown = HostCooldown(), plays: Plays? = nil, played: PlayedPage = PlayedPage()
    ) -> PageAnalyzer {
        let engine = DownloadEngine(configuration: .fast)
        let look: LookAgain? = plays.map { plays in { @Sendable _ in plays.record(); return played } }
        return PageAnalyzer(cooldown: cooldown, lookAgain: look) { url, options in try await engine.inspect(url, options: options) }
    }

    private func updates(_ stream: AsyncStream<PageAnalysis>) async -> [PageAnalysis] {
        var all: [PageAnalysis] = []
        for await update in stream { all.append(update) }
        return all
    }

    private func refused(_ site: Site, status: Int, body: String = "", headers: [String: String] = [:], at path: String) {
        site.server.serve(TestServer.File(
            data: Data(), headers: ["Content-Type": "text/html"],
            failFirst: .init(status: status, headers: headers.merging(["Content-Type": "text/html"]) { first, _ in first }, body: Data(body.utf8))
        ), at: path)
    }

    @Test func aPageAnsweringTooManyRequestsIsBlocked() async throws {
        let site = try await Site()
        refused(site, status: 429, at: "/watch")

        let found = await updates(analyzer().analyze(SentPage(url: site.url("/watch"))))

        #expect(found == [.blocked])
    }

    @Test func aChallengePageIsBlockedEvenWhenItAnswersOK() async throws {
        let site = try await Site()
        site.serve(html: Self.challenge, at: "/watch")

        let found = await updates(analyzer().analyze(SentPage(url: site.url("/watch"))))

        #expect(found == [.blocked])
    }

    @Test func aChallengePageThatAnswers403IsBlockedNotNeedingSignIn() async throws {
        let site = try await Site()
        refused(site, status: 403, body: Self.challenge, at: "/watch")

        let found = await updates(analyzer().analyze(SentPage(url: site.url("/watch"))))

        #expect(found == [.blocked])
    }

    @Test func aPageWithACaptchaOnItsLoginFormIsNotBlocked() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Clip</title><div class="g-recaptcha"></div><video src="/media/clip.mp4"></video>"#, at: "/watch")
        site.serve(video: 500, at: "/media/clip.mp4")

        let found = await updates(analyzer().analyze(SentPage(url: site.url("/watch"))))

        guard case .found(let candidates)? = found.last?.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
    }

    @Test func aBlockedPageTriesLookAgainOnceAndKeepsWhatItFinds() async throws {
        let site = try await Site()
        site.serve(html: Self.challenge, at: "/watch")
        site.serve(video: 4000, at: "/hidden/clip.mp4")
        let plays = Plays()
        let played = PlayedPage(title: "Real clip", media: [WatchedRequest(url: site.url("/hidden/clip.mp4"), kind: .file)], html: "<title>Real clip</title>")

        let found = await updates(analyzer(plays: plays, played: played).analyze(SentPage(url: site.url("/watch"))))

        #expect(found.first == .playing)
        guard case .found(let candidates)? = found.last?.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Real clip"])
        #expect(plays.count == 1)
    }

    @Test func aPageThatBlocksLookAgainToIsBlocked() async throws {
        let site = try await Site()
        site.serve(html: Self.challenge, at: "/watch")
        let plays = Plays()
        let played = PlayedPage(title: "Just a moment...", html: Self.challenge)

        let found = await updates(analyzer(plays: plays, played: played).analyze(SentPage(url: site.url("/watch"))))

        #expect(found == [.playing, .blocked])
        #expect(plays.count == 1)
    }

    @Test func aBlockedPageLookedAtAgainOnRequestSaysBlockedWhenItStillIs() async throws {
        let site = try await Site()
        let played = PlayedPage(title: "Just a moment...", html: Self.challenge)

        let found = await updates(analyzer(plays: Plays(), played: played).lookAgain(SentPage(url: site.url("/watch"))))

        #expect(found == [.playing, .blocked])
    }

    @Test func aHostIsNotAskedAgainUntilItsWaitIsOver() async throws {
        let site = try await Site()
        let cooldown = HostCooldown()
        let host = try #require(site.url("/").host(percentEncoded: false))
        await cooldown.cool(host, for: .milliseconds(400))
        site.serve(html: "<title>Plain</title>", at: "/watch")

        let start = ContinuousClock.now
        _ = await updates(analyzer(cooldown: cooldown).analyze(SentPage(url: site.url("/watch"))))

        #expect(ContinuousClock.now - start >= .milliseconds(350))
    }

    @Test func aTooManyRequestsReplyMakesThatHostWait() async throws {
        let site = try await Site()
        let cooldown = HostCooldown()
        let host = try #require(site.url("/").host(percentEncoded: false))
        refused(site, status: 429, headers: ["Retry-After": "2"], at: "/watch")

        _ = await updates(analyzer(cooldown: cooldown).analyze(SentPage(url: site.url("/watch"))))

        #expect(await cooldown.remaining(host) > .seconds(1))
    }

    @Test func aWaitIsNeverLongerThanHalfAMinute() async throws {
        let site = try await Site()
        let cooldown = HostCooldown()
        let host = try #require(site.url("/").host(percentEncoded: false))
        refused(site, status: 429, headers: ["Retry-After": "3600"], at: "/watch")

        _ = await updates(analyzer(cooldown: cooldown).analyze(SentPage(url: site.url("/watch"))))

        #expect(await cooldown.remaining(host) <= .seconds(30))
    }
}
