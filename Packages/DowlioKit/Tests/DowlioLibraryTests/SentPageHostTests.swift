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

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LookAgainHostTests {
    private final class Plays {
        var count = 0
        var stream: AsyncStream<PageAnalysis>.Continuation?

        func lookAgain(_ page: SentPage) -> AsyncStream<PageAnalysis> {
            count += 1
            let (stream, continuation) = AsyncStream.makeStream(of: PageAnalysis.self)
            self.stream = continuation
            return stream
        }
    }

    private let page = SentPage(url: URL(string: "https://a.example/watch")!)
    private let clip = Candidate(label: "Clip", versions: [Version(source: .file(URL(string: "https://a.example/clip.mp4")!))])

    private func host(_ plays: Plays) -> SentPageHost {
        SentPageHost(analyze: { _ in AsyncStream { $0.yield(.found([])) } }, lookAgain: plays.lookAgain)
    }

    @Test func lookAgainPlaysThePageAndShowsWhatItFinds() async throws {
        let plays = Plays()
        let host = host(plays)
        host.send(page) { _ in }
        try await waitUntil { host.current?.draft.phase == .nothingFound }

        host.current?.lookAgain()
        #expect(host.current?.draft.phase == .playing)
        plays.stream?.yield(.playing)
        plays.stream?.yield(.found([clip]))

        try await waitUntil { host.current?.draft.phase == .found }
        #expect(plays.count == 1)
        #expect(host.current?.draft.candidates == [clip])
    }

    @Test func cancellingPlayingStopsIt() async throws {
        let plays = Plays()
        let host = host(plays)
        host.send(page) { _ in }
        try await waitUntil { host.current?.draft.phase == .nothingFound }
        host.current?.lookAgain()

        host.current?.cancelPlaying()
        plays.stream?.yield(.found([clip]))
        try await Task.sleep(for: .milliseconds(50))

        #expect(host.current?.draft.phase == .nothingFound)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FeedHostTests {
    private final class Probes {
        var asked: [String] = []
    }

    private let page = SentPage(url: URL(string: "https://x.example/home")!)
    private let shown = Candidate(label: "Shown", versions: [Version(source: .file(URL(string: "https://x.example/a.mp4")!))], isOnScreen: true)
    private let waiting = Candidate(label: "Later", versions: [], unprobed: [WatchedRequest(url: URL(string: "https://x.example/b.m3u8")!, kind: .manifest)])

    @Test func openingAVideoThatWasntProbedProbesItOnce() async throws {
        let probes = Probes()
        let found = Version(source: .file(URL(string: "https://x.example/b.mp4")!))
        let host = SentPageHost(analyze: { [shown, waiting] _ in AsyncStream { $0.yield(.found([shown, waiting])) } }, probe: { _, candidate in
            probes.asked.append(candidate.label)
            var probed = candidate
            probed.versions = [found]
            probed.unprobed = []
            return probed
        })
        host.send(page) { _ in }
        try await waitUntil { host.current?.draft.candidates.count == 2 }

        host.current?.select(1)
        host.current?.select(1)
        try await waitUntil { host.current?.draft.candidates[1].versions == [found] }

        #expect(probes.asked == ["Later"])
        #expect(host.current?.draft.chosenVersion == found)
        host.current?.include(0, true)
        host.current?.include(1, true)
        #expect(host.current?.draft.downloads.count == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
