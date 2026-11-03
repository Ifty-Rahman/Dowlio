import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

@MainActor
private func firstPage(of list: LinkList) -> SentPageModel? {
    switch list.items.first?.kind {
    case .page(let page)?, .video(let page, _)?: page
    default: nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LookAgainTests {
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

    private func list(_ plays: Plays) -> LinkList {
        LinkList(analyze: { _ in AsyncStream { $0.yield(.found([])) } }, lookAgain: plays.lookAgain)
    }

    @Test func lookAgainPlaysThePageAndShowsWhatItFinds() async throws {
        let plays = Plays()
        let list = list(plays)
        list.send(page)
        try await waitUntil { firstPage(of: list)?.draft.phase == .nothingFound }

        firstPage(of: list)?.lookAgain()
        #expect(firstPage(of: list)?.draft.phase == .playing)
        plays.stream?.yield(.playing)
        plays.stream?.yield(.found([clip]))

        try await waitUntil { firstPage(of: list)?.draft.phase == .found }
        #expect(plays.count == 1)
        #expect(firstPage(of: list)?.draft.candidates == [clip])
    }

    @Test func cancellingPlayingStopsIt() async throws {
        let plays = Plays()
        let list = list(plays)
        list.send(page)
        try await waitUntil { firstPage(of: list)?.draft.phase == .nothingFound }
        firstPage(of: list)?.lookAgain()

        firstPage(of: list)?.cancelPlaying()
        plays.stream?.yield(.found([clip]))
        try await Task.sleep(for: .milliseconds(50))

        #expect(firstPage(of: list)?.draft.phase == .nothingFound)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FeedPageTests {
    private final class Probes {
        var asked: [String] = []
    }

    private let page = SentPage(url: URL(string: "https://x.example/home")!)
    private let shown = Candidate(label: "Shown", versions: [Version(source: .file(URL(string: "https://x.example/a.mp4")!))], isOnScreen: true)
    private let waiting = Candidate(label: "Later", versions: [], unprobed: [WatchedRequest(url: URL(string: "https://x.example/b.m3u8")!, kind: .manifest)])

    @Test func openingAVideoThatWasntProbedProbesItOnceAndDownloadWaitsForIt() async throws {
        let probes = Probes()
        let found = Version(source: .file(URL(string: "https://x.example/b.mp4")!))
        let list = LinkList(analyze: { [shown, waiting] _ in AsyncStream { $0.yield(.found([shown, waiting])) } }, probe: { _, candidate in
            probes.asked.append(candidate.label)
            var probed = candidate
            probed.versions = [found]
            probed.unprobed = []
            return probed
        })
        list.send(page)
        try await waitUntil { list.items.count == 2 }
        list.include(list.items[0].id, true)
        list.include(list.items[1].id, true)
        #expect(list.isWaiting)

        list.show(1)
        list.show(1)
        try await waitUntil { firstPage(of: list)?.draft.candidates[1].versions == [found] }

        #expect(probes.asked == ["Later"])
        #expect(list.chosenVersion(of: list.items[1].id) == found)
        #expect(!list.isWaiting)
        #expect(list.downloads.count == 2)
    }

    @Test func eachPageStartsOnTheCurrentQualityPreference() {
        var preference = QualityPreference(quality: .best)
        let list = LinkList(analyze: { _ in AsyncStream { $0.finish() } }, preference: { preference })
        preference = QualityPreference(quality: .upTo(480))

        list.send(SentPage(url: URL(string: "https://www.example.com/watch")!))

        #expect(firstPage(of: list)?.draft.preference == QualityPreference(quality: .upTo(480)))
    }
}
