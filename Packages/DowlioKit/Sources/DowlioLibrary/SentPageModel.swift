import DowlioCore
import DowlioMedia
import Foundation
import Observation

public struct ToolConsent: Sendable {
    public var size: @Sendable () async -> Int64?
    public var install: @Sendable (_ keepsUpToDate: Bool?) async throws -> Void

    public init(size: @escaping @Sendable () async -> Int64?, install: @escaping @Sendable (_ keepsUpToDate: Bool?) async throws -> Void) {
        self.size = size
        self.install = install
    }
}

@MainActor
@Observable
public final class SentPageModel {
    public private(set) var draft: SentPageDraft
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private let playPage: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let analyzePage: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let tools: ToolConsent?
    @ObservationIgnored private var installing: Task<Void, Never>?
    @ObservationIgnored private var sizing: Task<Void, Never>?
    @ObservationIgnored private let probeCandidate: (SentPage, Candidate) async -> Candidate
    @ObservationIgnored private var probes: [Task<Void, Never>] = []
    @ObservationIgnored private var probing: [Candidate] = []
    @ObservationIgnored private var following: Task<URL?, Never>?

    init(
        page: SentPage, preference: QualityPreference, playPage: @escaping (SentPage) -> AsyncStream<PageAnalysis>,
        analyzePage: @escaping (SentPage) -> AsyncStream<PageAnalysis>, tools: ToolConsent?,
        probe: @escaping (SentPage, Candidate) async -> Candidate
    ) {
        draft = SentPageDraft(page: page, preference: preference)
        self.playPage = playPage
        self.analyzePage = analyzePage
        self.tools = tools
        probeCandidate = probe
    }

    public func agreeToTools(keepUpToDate: Bool) {
        install(keepingUpToDate: keepUpToDate)
    }

    public func reinstallTools() {
        install(keepingUpToDate: nil)
    }

    private func install(keepingUpToDate keeps: Bool?) {
        guard let tools else { return }
        draft.startInstallingTools()
        installing?.cancel()
        installing = Task { [weak self] in
            do {
                try await tools.install(keeps)
                guard let self, !Task.isCancelled else { return }
                listen(to: analyzePage(draft.page))
            } catch {
                guard let self, !Task.isCancelled else { return }
                draft.failInstallingTools()
            }
        }
    }

    public func checkForToolUpdate() {
        tryAgain()
    }

    public func tryAgain() {
        draft.startLookingAgain()
        listen(to: analyzePage(draft.page))
    }

    public func declineTools() {
        draft.declineTools()
    }

    public func askForToolsAgain() {
        draft.askForToolsAgain()
    }

    private func sizeToolsIfNeeded() {
        guard draft.phase == .needsTools, draft.toolsSize == nil, sizing == nil, let tools else { return }
        sizing = Task { [weak self] in
            let size = await tools.size()
            guard let self, !Task.isCancelled else { return }
            draft.setToolsSize(size)
        }
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
        let task = Task { [weak self] () -> URL? in
            for await update in updates {
                guard let self, !Task.isCancelled else { return nil }
                if let file = draft.update(update) { return file }
                sizeToolsIfNeeded()
            }
            return nil
        }
        following = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    public func stopChecking() {
        guard draft.isCheckingForMore else { return }
        following?.cancel()
        draft.stopChecking()
    }

    func stop() {
        analysis?.cancel()
        installing?.cancel()
        sizing?.cancel()
        following?.cancel()
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
