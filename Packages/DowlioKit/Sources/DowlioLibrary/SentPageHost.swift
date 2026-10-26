import DowlioCore
import DowlioMedia
import Foundation
import Observation

@MainActor
@Observable
public final class SentPageModel {
    public private(set) var draft: SentPageDraft
    @ObservationIgnored private var analysis: Task<Void, Never>?

    init(page: SentPage, preference: QualityPreference) {
        draft = SentPageDraft(page: page, preference: preference)
    }

    func listen(to updates: AsyncStream<PageAnalysis>, handBack: @escaping (URL) -> Void) {
        analysis = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                if let file = draft.update(update) { return handBack(file) }
            }
        }
    }

    func stop() {
        analysis?.cancel()
    }

    public func select(_ index: Int) { draft.select(index) }
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

    public init(
        analyze: @escaping (SentPage) -> AsyncStream<PageAnalysis>,
        preference: @escaping () -> QualityPreference = { QualityPreference() }
    ) {
        self.analyze = analyze
        self.preference = preference
    }

    public func send(_ page: SentPage, handBack: ((URL) -> Void)? = nil) {
        current?.stop()
        let model = SentPageModel(page: page, preference: preference())
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
