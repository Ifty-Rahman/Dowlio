import DowlioCore
import DowlioMedia
import Foundation
import Observation

@MainActor
@Observable
public final class SentPageModel {
    public private(set) var draft: SentPageDraft
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private let playPage: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let probeCandidate: (SentPage, Candidate) async -> Candidate
    @ObservationIgnored private var probes: [Task<Void, Never>] = []
    @ObservationIgnored private var probing: [Candidate] = []

    init(
        page: SentPage, preference: QualityPreference, playPage: @escaping (SentPage) -> AsyncStream<PageAnalysis>,
        probe: @escaping (SentPage, Candidate) async -> Candidate
    ) {
        draft = SentPageDraft(page: page, preference: preference)
        self.playPage = playPage
        probeCandidate = probe
    }

    private func probeIfNeeded(_ index: Int) {
        guard draft.candidates.indices.contains(index), draft.candidates[index].needsProbe, !probing.contains(draft.candidates[index]) else { return }
        let candidate = draft.candidates[index]
        let page = draft.page
        probing.append(candidate)
        probes.append(Task { [weak self, probeCandidate] in
            let found = await probeCandidate(page, candidate)
            guard let self, !Task.isCancelled else { return }
            probing.removeAll { $0 == candidate }
            draft.replace(candidate, with: found)
        })
    }

    public func lookAgain() {
        draft.lookAgain()
        listen(to: playPage(draft.page))
    }

    public func cancelPlaying() {
        guard draft.phase == .playing else { return }
        analysis?.cancel()
        draft.cancelPlaying()
    }

    private func listen(to updates: AsyncStream<PageAnalysis>) {
        analysis?.cancel()
        analysis = Task { [weak self] in _ = await self?.follow(updates) }
    }

    func follow(_ updates: AsyncStream<PageAnalysis>) async -> URL? {
        for await update in updates {
            guard !Task.isCancelled else { return nil }
            if let file = draft.update(update) { return file }
        }
        return nil
    }

    func stop() {
        analysis?.cancel()
        probes.forEach { $0.cancel() }
    }

    public func select(_ index: Int) {
        draft.select(index)
        probeIfNeeded(index)
    }
    public func pick(_ version: Version) { draft.pick(version) }
    public func include(_ index: Int, _ included: Bool) { draft.include(index, included) }
    public func show(_ kind: SentPageDraft.Showing) { draft.show(kind) }
    public func moveChoice(by step: Int) { draft.moveChoice(by: step) }
}
