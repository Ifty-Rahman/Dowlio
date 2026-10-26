import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Observation

@MainActor
@Observable
final class SentPageModel {
    private(set) var draft: SentPageDraft
    private let analyzer: PageAnalyzer
    private let handBack: (URL) -> Void
    @ObservationIgnored private var analysis: Task<Void, Never>?

    init(page: SentPage, analyzer: PageAnalyzer, handBack: @escaping (URL) -> Void) {
        draft = SentPageDraft(page: page)
        self.analyzer = analyzer
        self.handBack = handBack
    }

    func start() {
        analysis?.cancel()
        let updates = analyzer.analyze(draft.page)
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

    func choose(_ candidate: Candidate) { draft.choose(candidate) }
    func backToList() { draft.backToList() }
    func pick(_ version: Version) { draft.pick(version) }
    func started(_ id: DownloadID) { draft.started(id) }
}
