import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct CheckingForMoreTests {
    private let page = SentPage(url: URL(string: "https://tube.example/watch/1")!)
    private let small = Version(source: .file(URL(string: "https://tube.example/clip-360p.mp4")!), contentType: "video/mp4", totalBytes: 1_000, height: 360)
    private let large = Version(source: .file(URL(string: "https://tube.example/clip-1080p.mp4")!), contentType: "video/mp4", totalBytes: 9_000, height: 1080)

    @Test func theRowsFoundSoFarShowWhileDowlioChecksForMore() {
        var draft = SentPageDraft(page: page)

        _ = draft.update(.checkingForMore([Candidate(label: "Clip", versions: [small])]))

        #expect(draft.phase == .found)
        #expect(draft.isCheckingForMore)
        #expect(draft.checkingLine == "Checking for more versions")
        #expect(draft.candidates.flatMap(\.versions) == [small])
    }

    @Test func moreVersionsJoinTheShownRowsAndKeepTheChoiceMade() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.checkingForMore([Candidate(label: "Clip", versions: [small])]))
        draft.pick(small)

        _ = draft.update(.found([Candidate(label: "Clip", versions: [small, large])]))

        #expect(!draft.isCheckingForMore)
        #expect(draft.candidates.flatMap(\.versions) == [small, large])
        #expect(draft.chosenVersion == small)
    }

    @Test func theChosenVideoStaysChosenWhenMoreVideosArrive() {
        var draft = SentPageDraft(page: page)
        let clip = Candidate(label: "Clip", versions: [small])
        let other = Candidate(label: "Other", versions: [large])
        _ = draft.update(.checkingForMore([clip]))
        draft.pick(small)

        _ = draft.update(.found([other, clip]))

        #expect(draft.selected == 1)
        #expect(draft.chosenVersion == small)
    }

    @Test func stoppingTheCheckKeepsTheRows() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.checkingForMore([Candidate(label: "Clip", versions: [small])]))

        draft.stopChecking()

        #expect(!draft.isCheckingForMore)
        #expect(draft.phase == .found)
        #expect(draft.candidates.flatMap(\.versions) == [small])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CheckingForMoreListTests {
    @Test func cancellingTheCheckKeepsTheRowsAndStopsTheAnalysis() async throws {
        let clip = Candidate(label: "Clip", versions: [Version(source: .file(URL(string: "https://a.example/clip.mp4")!))])
        let ended = Ended()
        let list = LinkList(analyze: { _ in
            AsyncStream { continuation in
                continuation.yield(.checkingForMore([clip]))
                continuation.onTermination = { _ in ended.note() }
            }
        }, lookAgain: { _ in .nothingFound })
        list.send(SentPage(url: URL(string: "https://a.example/watch")!))
        try await waitUntil { model(of: list)?.draft.isCheckingForMore == true }

        model(of: list)?.stopChecking()

        try await waitUntil { ended.happened }
        #expect(model(of: list)?.draft.isCheckingForMore == false)
        #expect(model(of: list)?.draft.candidates == [clip])
    }

    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var happened: Bool { lock.withLock { ended } }
        func note() { lock.withLock { ended = true } }
    }

    private func model(of list: LinkList) -> SentPageModel? {
        switch list.items.first?.kind {
        case .page(let page)?, .video(let page, _)?: page
        default: nil
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
