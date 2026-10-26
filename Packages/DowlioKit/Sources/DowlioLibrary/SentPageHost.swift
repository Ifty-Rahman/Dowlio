import DowlioCore
import DowlioMedia
import Foundation
import Observation

@MainActor
@Observable
public final class SentPageModel {
    public private(set) var draft: SentPageDraft
    @ObservationIgnored private var analysis: Task<Void, Never>?

    init(page: SentPage) {
        draft = SentPageDraft(page: page)
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

    public func choose(_ candidate: Candidate) { draft.choose(candidate) }
    public func backToList() { draft.backToList() }
    public func pick(_ version: Version) { draft.pick(version) }
    public func started(_ id: DownloadID) { draft.started(id) }
}

@MainActor
@Observable
public final class SentPageHost {
    public private(set) var current: SentPageModel?
    @ObservationIgnored private let analyze: (SentPage) -> AsyncStream<PageAnalysis>

    public init(analyze: @escaping (SentPage) -> AsyncStream<PageAnalysis>) {
        self.analyze = analyze
    }

    public func send(_ page: SentPage, handBack: @escaping (URL) -> Void) {
        current?.stop()
        let model = SentPageModel(page: page)
        current = model
        model.listen(to: analyze(page)) { [weak self, weak model] file in
            if let self, self.current === model { self.current = nil }
            handBack(file)
        }
    }

    public func backToLinks() {
        current?.stop()
        current = nil
    }

    public static func backTitle(links: Int) -> String? {
        switch links {
        case 0: nil
        case 1: "Back to 1 link"
        default: "Back to \(links) links"
        }
    }
}
