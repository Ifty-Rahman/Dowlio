import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LinkListTests {
    private final class Analyses {
        var streams: [URL: AsyncStream<PageAnalysis>.Continuation] = [:]
        var asked: [SentPage] = []

        func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
            let (stream, continuation) = AsyncStream.makeStream(of: PageAnalysis.self)
            streams[page.url] = continuation
            asked.append(page)
            return stream
        }

        func finish(_ url: URL, with analysis: PageAnalysis) {
            streams[url]?.yield(analysis)
            streams[url]?.finish()
        }
    }

    private let pageA = URL(string: "https://a.example/watch")!
    private let pageB = URL(string: "https://b.example/watch")!
    private let file = URL(string: "https://files.example/report.pdf")!
    private let mp4 = Version(source: .file(URL(string: "https://a.example/one.mp4")!), contentType: "video/mp4", height: 1080)
    private let small = Version(source: .file(URL(string: "https://a.example/one-480.mp4")!), contentType: "video/mp4", height: 480)
    private let m4a = Version(source: .file(URL(string: "https://a.example/one.m4a")!), contentType: "audio/mp4")
    private var one: Candidate { Candidate(label: "One", versions: [mp4, small, m4a]) }
    private var two: Candidate { Candidate(label: "Two", versions: [Version(source: .file(URL(string: "https://a.example/two.mp4")!), contentType: "video/mp4")]) }
    private var three: Candidate { Candidate(label: "Three", versions: [Version(source: .file(URL(string: "https://b.example/three.mp4")!), contentType: "video/mp4")]) }

    private static let webPage = LinkInspection(
        fileName: "watch.html", totalBytes: nil, contentType: "text/html", category: .documents,
        splitsIntoSegments: false, cannotResumeBecause: .sizeUnknown, isNotSecure: false
    )
    private static let pdf = LinkInspection(
        fileName: "report.pdf", totalBytes: 10, contentType: "application/pdf", category: .documents,
        splitsIntoSegments: true, cannotResumeBecause: nil, isNotSecure: false
    )

    private func list(_ analyses: Analyses) -> LinkList {
        LinkList(analyze: analyses.analyze)
    }

    private func describe(_ list: LinkList) -> [String] {
        list.items.map { item in
            switch item.kind {
            case .checking(let url): "checking \(url.host() ?? "")"
            case .file(let url, _): "file \(url.lastPathComponent)"
            case .page(let page): "page \(page.draft.page.url.host() ?? "") \(page.draft.phase)"
            case .video(let page, let index): "video \(page.draft.candidates[index].label)"
            }
        }
    }

    @Test func aPagesVideosAreListedOneAfterAnother() async throws {
        let analyses = Analyses()
        let list = list(analyses)

        list.update(link: pageA)
        #expect(describe(list) == ["checking a.example"])

        list.checked(pageA, .inspected(Self.webPage))
        #expect(describe(list) == ["page a.example looking"])
        analyses.finish(pageA, with: .found([one, two]))

        try await waitUntil { describe(list) == ["video One", "video Two"] }
        #expect(analyses.asked.map(\.url) == [pageA])
    }

    @Test(arguments: [400, 405])
    func aLinkTheServerRefusesTheFileCheckWithAStatusIsReadAsAPage(status: Int) async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)

        list.checked(pageA, .failed(.network(Self.answered(status))))

        #expect(describe(list) == ["page a.example looking"])
    }

    @Test func aLinkBlockedForLegalReasonsStaysAFailedFile() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)

        list.checked(pageA, .failed(.network(Self.answered(451))))

        #expect(analyses.asked.isEmpty)
    }

    @Test func aLinkTheServerIsTooBusyToCheckStaysAFailedFile() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)

        list.checked(pageA, .failed(.network(NetworkFailure(code: .badServerResponse, message: "The server is busy or failing."))))

        #expect(analyses.asked.isEmpty)
    }

    @Test func aLinkThatLostItsConnectionStaysAFailedFile() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)

        list.checked(pageA, .failed(.network(NetworkFailure(code: .networkConnectionLost, message: "The network connection was lost."))))

        #expect(analyses.asked.isEmpty)
    }

    private static func answered(_ status: Int) -> NetworkFailure {
        NetworkFailure(code: .badServerResponse, message: "The server answered with status \(status).", status: status)
    }

    @Test func aSentPageReplacesWhatTheListHeldAndStopsItsAnalysis() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)
        list.checked(pageA, .inspected(Self.webPage))
        let sent = SentPage(url: pageB, title: "Holiday", browser: "Dia")

        list.send(sent)
        analyses.finish(pageA, with: .found([one, two]))
        analyses.finish(pageB, with: .found([three]))

        try await waitUntil { describe(list) == ["video Three"] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(describe(list) == ["video Three"])
        #expect(list.positionLine == "1 of 1")
    }

    @Test func aNewLinkReplacesTheOldOneAndItsName() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: file)
        list.checked(file, .inspected(Self.pdf))
        let report = list.items[0].id
        list.rename(report, "Q3.pdf")

        list.update(link: pageA)
        #expect(describe(list) == ["checking a.example"])
        list.update(link: file)
        list.checked(file, .inspected(Self.pdf))

        #expect(list.name(of: list.items[0].id) == nil)
    }

    @Test func noLinkEmptiesTheList() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)

        list.update(link: nil)

        #expect(list.items.isEmpty)
    }

    @Test func aPageWithNoVideoIsAnItemThatSaysSo() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)
        list.checked(pageA, .inspected(Self.webPage))

        analyses.finish(pageA, with: .found([]))

        try await waitUntil { describe(list) == ["page a.example nothingFound"] }
    }

    @Test func aPageIsAnalysedWithTheCookiesAndUserAgentOfItsLink() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        var options = RequestOptions()
        options.cookies = [Cookie(name: "session", value: "abc")]
        options.userAgent = "Mozilla/5.0 Arc"

        list.update(link: pageA, options: options)
        list.checked(pageA, .inspected(Self.webPage))

        #expect(analyses.asked == [SentPage(url: pageA, cookies: options.cookies, userAgent: "Mozilla/5.0 Arc")])
    }

    @Test func nextAndPreviousMoveThroughTheItemsAndThePositionReadsLikeTwoOfThree() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)

        #expect(list.positionLine == "1 of 3")
        list.previous()
        #expect(list.position == 0)
        list.next()
        #expect(list.positionLine == "2 of 3")
        #expect(list.current != nil && describe(list)[list.position] == "video Two")
        list.next()
        list.next()
        #expect(list.positionLine == "3 of 3")
    }

    @Test func eachVideoKeepsItsOwnVersionIncludeAndFileNameWhileMoving() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)
        let first = try #require(list.current)

        list.pick(small)
        list.include(first.id, true)
        list.rename(first.id, "Beach")
        list.next()
        list.next()
        list.previous()
        list.previous()

        #expect(list.chosenVersion(of: first.id) == small)
        #expect(list.isIncluded(first.id))
        #expect(list.name(of: first.id) == "Beach")
        #expect(list.chosenVersion(of: list.items[1].id) != small)
        #expect(!list.isIncluded(list.items[1].id))
    }

    @Test func aVideosFileNameGoesWithTheVersionItWasGivenFor() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)
        let first = list.items[0].id

        list.rename(first, "  Beach  ")
        #expect(list.name(of: first) == "Beach")
        list.pick(small)

        #expect(list.name(of: first) == nil)
    }

    @Test func downloadAddsEveryIncludedItemWithItsOwnChoices() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)
        let (first, second, third) = (list.items[0].id, list.items[1].id, list.items[2].id)
        #expect(list.downloads.isEmpty)

        list.include(first, true)
        list.pick(m4a)
        list.include(second, true)
        list.include(third, true)
        list.rename(third, "Harbour")

        let page = SentPage(url: pageA, cookies: [], userAgent: nil)
        #expect(list.downloads == [
            .media(page: page, candidate: one, version: m4a, name: nil),
            .media(page: page, candidate: two, version: two.versions[0], name: nil),
            .media(page: page, candidate: three, version: three.versions[0], name: "Harbour"),
        ])
        #expect(list.includedLine == "3 of 3 included")

        list.include(third, false)
        #expect(list.downloads.count == 2)
    }

    @Test func aPageThatTurnsOutToBeAFileBecomesAFileItem() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        let sent = SentPage(url: file, browser: "Dia")

        list.send(sent)
        analyses.finish(file, with: .plainFile(file))

        try await waitUntil { describe(list) == ["file report.pdf"] }
        #expect(list.downloads == [.file(file, name: nil)])
    }

    @Test func aLoneFileDownloadsWithoutTicking() {
        let list = list(Analyses())
        list.update(link: file)
        list.checked(file, .inspected(Self.pdf))

        #expect(list.downloads == [.file(file, name: nil)])
    }

    @Test func aLonePagesOnlyVideoDownloadsWithoutTicking() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageB)
        list.checked(pageB, .inspected(Self.webPage))
        #expect(list.isWaiting)

        analyses.finish(pageB, with: .found([three]))
        try await waitUntil { describe(list) == ["video Three"] }

        #expect(list.downloads.map(\.isMedia) == [true])
    }

    @Test func aLonePageWithNoVideoStaysOff() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(link: pageA)
        list.checked(pageA, .inspected(Self.webPage))

        analyses.finish(pageA, with: .found([]))
        try await waitUntil { describe(list) == ["page a.example nothingFound"] }

        #expect(list.downloads.isEmpty)
    }

    @Test func clearingEmptiesTheList() async throws {
        let analyses = Analyses()
        let list = try await threeVideos(analyses)

        list.clear()

        #expect(list.items.isEmpty)
        #expect(list.downloads.isEmpty)
    }

    private func threeVideos(_ analyses: Analyses) async throws -> LinkList {
        let list = list(analyses)
        list.update(link: pageA)
        list.checked(pageA, .inspected(Self.webPage))
        analyses.finish(pageA, with: .found([one, two, three]))
        try await waitUntil { describe(list) == ["video One", "video Two", "video Three"] }
        return list
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}

private extension LinkDownload {
    var isMedia: Bool { if case .media = self { true } else { false } }
}
