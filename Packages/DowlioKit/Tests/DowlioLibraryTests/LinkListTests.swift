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

    @Test func eachLinkIsAnalysedOnItsOwnAndItsVideosOrFileJoinOneListInTheOrderTheLinksWereAdded() async throws {
        let analyses = Analyses()
        let list = list(analyses)

        list.update(links: [pageA, file, pageB])
        #expect(describe(list) == ["checking a.example", "checking files.example", "checking b.example"])

        list.checked(pageB, .inspected(Self.webPage))
        list.checked(file, .inspected(Self.pdf))
        list.checked(pageA, .inspected(Self.webPage))
        analyses.finish(pageB, with: .found([three]))
        analyses.finish(pageA, with: .found([one, two]))

        try await waitUntil { describe(list) == ["video One", "video Two", "file report.pdf", "video Three"] }
        #expect(analyses.asked.map(\.url) == [pageB, pageA])
    }

    @Test func aPageIsAnalysedWithTheCookiesAndUserAgentOfItsLink() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        var options = RequestOptions()
        options.cookies = [Cookie(name: "session", value: "abc")]
        options.userAgent = "Mozilla/5.0 Arc"

        list.update(links: [pageA]) { _ in options }
        list.checked(pageA, .inspected(Self.webPage))

        #expect(analyses.asked == [SentPage(url: pageA, cookies: options.cookies, userAgent: "Mozilla/5.0 Arc")])
    }

    @Test func atMostFourPagesAreAnalysedAtATime() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        let pages = (1...6).map { URL(string: "https://p\($0).example/watch")! }

        list.update(links: pages)
        for page in pages { list.checked(page, .inspected(Self.webPage)) }
        #expect(analyses.asked.map(\.url) == Array(pages.prefix(4)))
        #expect(describe(list)[5] == "page p6.example looking")

        analyses.finish(pages[1], with: .found([two]))
        try await waitUntil { analyses.asked.count == 5 }
        #expect(analyses.asked.last?.url == pages[4])
    }

    @Test func aPageSentFromTheBrowserJoinsTheOpenListAfterWhatIsThere() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(links: [file])
        list.checked(file, .inspected(Self.pdf))
        let sent = SentPage(url: pageA, title: "Holiday", browser: "Dia")

        list.send(sent)
        list.update(links: [file, pageA])

        #expect(analyses.asked == [sent])
        #expect(describe(list) == ["file report.pdf", "page a.example looking"])
    }

    @Test func aLinkTakenOutOfTheFieldLeavesTheList() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(links: [pageA, file])
        list.checked(file, .inspected(Self.pdf))

        list.update(links: [file])

        #expect(describe(list) == ["file report.pdf"])
    }

    @Test func nextAndPreviousMoveThroughTheItemsAndThePositionReadsLikeTwoOfThree() async throws {
        let analyses = Analyses()
        let list = try await threeItems(analyses)

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
        let list = try await threeItems(analyses)
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
        let list = try await threeItems(analyses)
        let first = list.items[0].id

        list.rename(first, "  Beach  ")
        #expect(list.name(of: first) == "Beach")
        list.pick(small)

        #expect(list.name(of: first) == nil)
    }

    @Test func aNameLeavesWithItsLink() async throws {
        let analyses = Analyses()
        let list = try await threeItems(analyses)
        let report = list.items[2].id
        list.rename(report, "Q3.pdf")

        list.update(links: [pageA])
        list.update(links: [pageA, file])
        list.checked(file, .inspected(Self.pdf))

        #expect(list.name(of: list.items[2].id) == nil)
        #expect(list.name(of: report) == nil)
    }

    @Test func downloadAddsEveryIncludedItemWithItsOwnChoices() async throws {
        let analyses = Analyses()
        let list = try await threeItems(analyses)
        let (first, second, report) = (list.items[0].id, list.items[1].id, list.items[2].id)
        #expect(list.downloads == [.file(file, name: nil)])

        list.include(first, true)
        list.pick(m4a)
        list.include(second, true)
        list.rename(report, "Q3 report.pdf")

        let page = SentPage(url: pageA, cookies: [], userAgent: nil)
        #expect(list.downloads == [
            .media(page: page, candidate: one, version: m4a, name: nil),
            .media(page: page, candidate: two, version: two.versions[0], name: nil),
            .file(file, name: "Q3 report.pdf"),
        ])
        #expect(list.includedLine == "3 of 3 included")

        list.include(report, false)
        #expect(list.downloads.count == 2)
    }

    @Test func downloadWaitsOnlyForIncludedItemsStillLooking() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(links: [file, pageA])
        list.checked(file, .inspected(Self.pdf))
        #expect(list.isWaiting)

        let looking = list.items[1].id
        list.include(looking, false)

        #expect(!list.isWaiting)
        #expect(list.downloads == [.file(file, name: nil)])
    }

    @Test func aPageWithNoVideoIsAnItemThatSaysSoStartsUntickedAndDownloadsAsAFileWhenTicked() async throws {
        let analyses = Analyses()
        let list = list(analyses)
        list.update(links: [pageA, file])
        list.checked(file, .inspected(Self.pdf))
        list.checked(pageA, .inspected(Self.webPage))

        analyses.finish(pageA, with: .found([]))
        try await waitUntil { describe(list).first == "page a.example nothingFound" }

        let page = list.items[0].id
        #expect(!list.isIncluded(page))
        list.include(page, true)
        #expect(list.downloads == [.file(pageA, name: nil), .file(file, name: nil)])
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

    @Test func clearingEmptiesTheList() async throws {
        let analyses = Analyses()
        let list = try await threeItems(analyses)

        list.clear()

        #expect(list.items.isEmpty)
        #expect(list.downloads.isEmpty)
    }

    private func threeItems(_ analyses: Analyses) async throws -> LinkList {
        let list = list(analyses)
        list.update(links: [pageA, file])
        list.checked(pageA, .inspected(Self.webPage))
        list.checked(file, .inspected(Self.pdf))
        analyses.finish(pageA, with: .found([one, two]))
        try await waitUntil { list.items.count == 3 && describe(list)[0] == "video One" }
        return list
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
