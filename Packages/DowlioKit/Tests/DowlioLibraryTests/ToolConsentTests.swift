import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ToolConsentTests {
    private let page = SentPage(url: URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!, browser: "Arc")

    @Test func aPageThatNeedsTheToolsAsksFirstNamingBothToolsTheirProjectsAndTheSize() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.needsTools)
        draft.toolsSize = 55_700_000

        #expect(draft.phase == .needsTools)
        let consent = draft.toolConsent
        #expect(consent.title == "Download yt-dlp and QuickJS-NG?")
        #expect(consent.explanation == "This site needs yt-dlp, a free open-source tool, and QuickJS-NG, which yt-dlp uses for YouTube. Dowlio downloads them from their GitHub pages. About 56 MB.")
        #expect(consent.tools.map(\.name) == ["yt-dlp", "QuickJS-NG"])
        #expect(consent.tools.map(\.project) == [URL(string: "https://github.com/yt-dlp/yt-dlp")!, URL(string: "https://github.com/quickjs-ng/quickjs")!])
        #expect(consent.keepsUpToDate)
        #expect(consent.agree == "Download")
        #expect(consent.decline == "Not Now")
    }

    @Test func beforeTheSizeIsKnownTheExplanationLeavesItOut() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.needsTools)

        #expect(draft.toolConsent.explanation.hasSuffix("Dowlio downloads them from their GitHub pages."))
    }

    private func sent(analyze: @escaping (SentPage) -> AsyncStream<PageAnalysis>, install: @escaping @Sendable (Bool?) async throws -> Void) async throws -> SentPageModel {
        let list = LinkList(analyze: analyze, tools: ToolConsent(size: { nil }, install: install))
        list.send(page)
        try await waitOnMain { pageModel(of: list)?.draft.phase == .needsTools }
        return try #require(pageModel(of: list))
    }

    @Test func decliningDownloadsNothingAndSaysWhyThereIsNothingToShow() async throws {
        let installs = Counter()
        let model = try await sent(analyze: { _ in .once(.needsTools) }, install: { _ in installs.add() })

        model.declineTools()

        #expect(model.draft.phase == .declinedTools)
        #expect(model.draft.declinedLine == "Dowlio needs yt-dlp to read this page. Nothing was downloaded.")
        #expect(installs.count == 0)
    }

    @Test func agreeingInstallsTheToolsThenReadsThePageAgain() async throws {
        let installs = Counter()
        let kept = Counter()
        let video = Candidate(label: "Perfect", versions: [])
        let model = try await sent(
            analyze: { _ in installs.count == 0 ? .once(.needsTools) : .once(.found([video])) },
            install: { keeps in
                if keeps == true { kept.add() }
                installs.add()
            }
        )

        model.agreeToTools(keepUpToDate: true)
        try await waitOnMain { model.draft.phase == .found }

        #expect(installs.count == 1)
        #expect(kept.count == 1)
        #expect(model.draft.candidates == [video])
    }

    @Test func aFailedInstallSaysSoAndOffersTryingAgain() async throws {
        let model = try await sent(analyze: { _ in .once(.needsTools) }, install: { _ in throw ToolInstaller.Failure.network })

        model.agreeToTools(keepUpToDate: false)
        try await waitOnMain { model.draft.phase == .couldntInstallTools }

        #expect(model.draft.couldntInstallLine == "Dowlio couldn't download yt-dlp and QuickJS-NG from GitHub. Check your connection and try again.")
    }

    @Test func aToolThatChangedOffersReinstallingIt() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.toolsChanged)

        #expect(draft.phase == .toolsChanged)
        #expect(draft.toolsChangedLine == "yt-dlp or QuickJS-NG changed since Dowlio installed it, so Dowlio won't run it. Reinstall it to read this page.")
    }
}

@MainActor
private func pageModel(of list: LinkList) -> SentPageModel? {
    switch list.items.first?.kind {
    case .page(let page)?, .video(let page, _)?: page
    default: nil
    }
}

@MainActor
private func waitOnMain(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() { lock.withLock { value += 1 } }

    var count: Int { lock.withLock { value } }
}

extension AsyncStream where Element == PageAnalysis {
    static func once(_ analysis: PageAnalysis) -> AsyncStream<PageAnalysis> {
        AsyncStream { continuation in
            continuation.yield(analysis)
            continuation.finish()
        }
    }
}
