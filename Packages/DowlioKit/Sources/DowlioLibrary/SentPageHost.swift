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
        listen(to: playPage(draft.page)) { _ in }
    }

    public func cancelPlaying() {
        guard draft.phase == .playing else { return }
        analysis?.cancel()
        draft.cancelPlaying()
    }

    func listen(to updates: AsyncStream<PageAnalysis>, handBack: @escaping (URL) -> Void) {
        analysis?.cancel()
        analysis = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                if let file = draft.update(update) { return handBack(file) }
            }
        }
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

@MainActor
@Observable
public final class SentPageHost {
    public private(set) var current: SentPageModel?
    @ObservationIgnored private let analyze: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let preference: () -> QualityPreference
    @ObservationIgnored private let lookAgain: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let probe: (SentPage, Candidate) async -> Candidate

    public init(
        analyze: @escaping (SentPage) -> AsyncStream<PageAnalysis>,
        lookAgain: @escaping (SentPage) -> AsyncStream<PageAnalysis> = { _ in .nothingFound },
        probe: @escaping (SentPage, Candidate) async -> Candidate = { $1 },
        preference: @escaping () -> QualityPreference = { QualityPreference() }
    ) {
        self.analyze = analyze
        self.lookAgain = lookAgain
        self.probe = probe
        self.preference = preference
    }

    public func send(_ page: SentPage, handBack: ((URL) -> Void)? = nil) {
        current?.stop()
        let model = SentPageModel(page: page, preference: preference(), playPage: lookAgain, probe: probe)
        current = model
        model.listen(to: analyze(page)) { [weak self, weak model] file in
            if let self, self.current === model { self.current = nil }
            handBack?(file)
        }
    }

    public func clear() {
        current?.stop()
        current = nil
    }
}
