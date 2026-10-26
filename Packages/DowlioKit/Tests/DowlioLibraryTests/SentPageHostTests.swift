import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SentPageHostTests {
    private final class Analyses {
        var streams: [URL: AsyncStream<PageAnalysis>.Continuation] = [:]

        func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
            let (stream, continuation) = AsyncStream.makeStream(of: PageAnalysis.self)
            streams[page.url] = continuation
            return stream
        }
    }

    private let first = SentPage(url: URL(string: "https://a.example/watch")!, browser: "Arc")
    private let second = SentPage(url: URL(string: "https://b.example/watch")!, browser: "Arc")
    private let clip = Candidate(label: "Clip", versions: [Version(source: .file(URL(string: "https://a.example/clip.mp4")!))])

    @Test func aSentPageShowsUntilItsVideoIsFound() async throws {
        let analyses = Analyses()
        let host = SentPageHost(analyze: analyses.analyze)

        host.send(first) { _ in }
        #expect(host.current?.draft.phase == .looking)

        analyses.streams[first.url]?.yield(.found([clip]))
        try await waitUntil { host.current?.draft.phase == .found && host.current?.draft.candidates == [clip] }
    }

    @Test func aSecondPageReplacesTheFirstAndTheFirstStopsListening() async throws {
        let analyses = Analyses()
        let host = SentPageHost(analyze: analyses.analyze)
        host.send(first) { _ in }
        let replaced = try #require(host.current)

        host.send(second) { _ in }
        analyses.streams[first.url]?.yield(.found([clip]))
        analyses.streams[first.url]?.finish()
        analyses.streams[second.url]?.yield(.found([]))
        try await waitUntil { host.current?.draft.phase == .nothingFound }

        #expect(host.current?.draft.page == second)
        #expect(replaced.draft.phase == .looking)
    }

    @Test func clearingDropsThePage() {
        let host = SentPageHost(analyze: Analyses().analyze)
        host.send(first) { _ in }

        host.clear()

        #expect(host.current == nil)
    }

    @Test func aPageThatIsAPlainFileIsHandedBackAndLeaves() async throws {
        let analyses = Analyses()
        let host = SentPageHost(analyze: analyses.analyze)
        let handedBack = HandedBack()
        host.send(first) { handedBack.url = $0 }

        analyses.streams[first.url]?.yield(.plainFile(first.url))

        try await waitUntil { handedBack.url == first.url && host.current == nil }
    }

    private final class HandedBack {
        var url: URL?
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
