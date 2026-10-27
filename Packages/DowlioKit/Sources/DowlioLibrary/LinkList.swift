import DowlioCore
import DowlioMedia
import Foundation
import Observation

public struct LinkItem: Identifiable {
    public struct ID: Hashable, Sendable {
        let entry: Int
        let candidate: Int?
    }

    public enum Kind {
        case checking(URL)
        case file(URL, NewDownloadDraft.Check?)
        case page(SentPageModel)
        case video(SentPageModel, Int)
    }

    public let id: ID
    public let kind: Kind
}

public enum LinkDownload: Equatable, Sendable {
    case media(page: SentPage, candidate: Candidate, version: Version, name: String?)
    case file(URL, name: String?)
}

@MainActor
@Observable
public final class LinkList {
    private enum State {
        case checking
        case file(URL, NewDownloadDraft.Check?)
        case waiting(SentPageModel)
        case page(SentPageModel)
    }

    private struct Entry {
        let id: Int
        let url: URL
        var options: RequestOptions
        var state: State
        var included = true
        var pageIncluded = false
        var analysis: Task<Void, Never>?
    }

    public static let analysedAtOnce = 4

    private var entries: [Entry] = []
    private var nextID = 0
    private var currentID: LinkItem.ID?
    private var lastPosition = 0
    private var names: [LinkItem.ID: (name: String, version: Version?)] = [:]
    @ObservationIgnored private let analyze: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let lookAgain: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let probe: (SentPage, Candidate) async -> Candidate
    @ObservationIgnored private let preference: () -> QualityPreference

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

    public func update(links: [URL], options: (URL) -> RequestOptions = { _ in RequestOptions() }) {
        for entry in entries where !links.contains(entry.url) { stop(entry) }
        let kept = entries.filter { links.contains($0.url) }
        names = names.filter { name in kept.contains { $0.id == name.key.entry } }
        entries = links.map { url in
            if var entry = kept.first(where: { $0.url == url }) {
                entry.options = options(url)
                return entry
            }
            return makeEntry(url, options: options(url), state: .checking)
        }
        startWaiting()
    }

    public func checked(_ url: URL, _ check: NewDownloadDraft.Check) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        switch entries[index].state {
        case .checking, .file:
            if case .inspected(let inspection) = check, inspection.isWebPage {
                let options = entries[index].options
                entries[index].state = .waiting(makeModel(SentPage(url: url, cookies: options.cookies, userAgent: options.userAgent)))
                startWaiting()
            } else {
                entries[index].state = .file(url, check)
            }
        case .waiting, .page:
            break
        }
    }

    public func send(_ page: SentPage) {
        if let index = entries.firstIndex(where: { $0.url == page.url }) {
            stop(entries[index])
            entries[index].analysis = nil
            entries[index].state = .waiting(makeModel(page))
            entries[index].included = true
        } else {
            entries.append(makeEntry(page.url, options: RequestOptions(), state: .waiting(makeModel(page))))
        }
        startWaiting()
    }

    public func clear() {
        entries.forEach(stop)
        entries = []
        names = [:]
        currentID = nil
        lastPosition = 0
    }

    private func makeEntry(_ url: URL, options: RequestOptions, state: State) -> Entry {
        nextID += 1
        return Entry(id: nextID, url: url, options: options, state: state)
    }

    private func makeModel(_ page: SentPage) -> SentPageModel {
        SentPageModel(page: page, preference: preference(), playPage: lookAgain, probe: probe)
    }

    private func stop(_ entry: Entry) {
        entry.analysis?.cancel()
        if case .page(let model) = entry.state { model.stop() }
    }

    private var analysing: Int {
        entries.filter { $0.analysis != nil }.count
    }

    private func startWaiting() {
        for index in entries.indices where analysing < Self.analysedAtOnce {
            guard case .waiting(let model) = entries[index].state else { continue }
            let id = entries[index].id
            let updates = analyze(model.draft.page)
            entries[index].state = .page(model)
            entries[index].analysis = Task { [weak self] in
                let file = await model.follow(updates)
                guard !Task.isCancelled else { return }
                self?.finished(id, handingBack: file)
            }
        }
    }

    private func finished(_ id: Int, handingBack file: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].analysis = nil
        if let file { entries[index].state = .file(file, nil) }
        startWaiting()
    }

    public var items: [LinkItem] {
        entries.flatMap { entry -> [LinkItem] in
            switch entry.state {
            case .checking:
                return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .checking(entry.url))]
            case .waiting(let model):
                return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .page(model))]
            case .file(let url, let check):
                return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .file(url, check))]
            case .page(let model):
                switch model.draft.phase {
                case .found, .restricted:
                    return model.draft.candidates.indices.map { LinkItem(id: .init(entry: entry.id, candidate: $0), kind: .video(model, $0)) }
                case .looking, .playing, .nothingFound, .needsSignIn:
                    return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .page(model))]
                }
            }
        }
    }

    public var position: Int {
        let items = items
        guard !items.isEmpty else { return 0 }
        if let currentID {
            if let exact = items.firstIndex(where: { $0.id == currentID }) { return exact }
            if let sameLink = items.firstIndex(where: { $0.id.entry == currentID.entry }) { return sameLink }
        }
        return min(lastPosition, items.count - 1)
    }

    public var current: LinkItem? {
        let items = items
        return items.indices.contains(position) ? items[position] : nil
    }

    public var positionLine: String {
        "\(position + 1) of \(items.count)"
    }

    public func show(_ index: Int) {
        let items = items
        guard items.indices.contains(index) else { return }
        currentID = items[index].id
        lastPosition = index
        if case .video(let model, let candidate) = items[index].kind { model.select(candidate) }
    }

    public func next() { show(position + 1) }
    public func previous() { show(position - 1) }

    public func pick(_ version: Version) {
        guard case .video(let model, let candidate)? = current?.kind else { return }
        model.select(candidate)
        model.pick(version)
    }

    public func chosenVersion(of id: LinkItem.ID) -> Version? {
        guard let item = items.first(where: { $0.id == id }), case .video(let model, let candidate) = item.kind else { return nil }
        return model.draft.chosenVersion(of: candidate)
    }

    public func isIncluded(_ id: LinkItem.ID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id.entry }) else { return false }
        switch entry.state {
        case .checking, .file:
            return entry.included
        case .waiting(let model), .page(let model):
            if let candidate = id.candidate {
                let restricted = model.draft.candidates.indices.contains(candidate) && model.draft.candidates[candidate].restriction != nil
                return entry.included && !restricted && model.draft.isIncluded(candidate)
            }
            return model.draft.phase.isLooking ? entry.included : entry.pageIncluded
        }
    }

    public func include(_ id: LinkItem.ID, _ included: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id.entry }) else { return }
        switch entries[index].state {
        case .checking, .file:
            entries[index].included = included
        case .waiting(let model), .page(let model):
            if let candidate = id.candidate {
                if included { entries[index].included = true }
                model.include(candidate, included)
            } else if model.draft.phase.isLooking {
                entries[index].included = included
            } else {
                entries[index].pageIncluded = included
            }
        }
    }

    public func name(of id: LinkItem.ID) -> String? {
        guard let named = names[id], named.version == chosenVersion(of: id) else { return nil }
        return named.name
    }

    public func rename(_ id: LinkItem.ID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        names[id] = trimmed.isEmpty ? nil : (trimmed, chosenVersion(of: id))
    }

    public var isWaiting: Bool {
        items.contains { item in
            guard isIncluded(item.id) else { return false }
            switch item.kind {
            case .checking: return true
            case .page(let model): return model.draft.phase.isLooking
            case .video(let model, let candidate): return model.draft.candidates[candidate].needsProbe
            case .file: return false
            }
        }
    }

    public var downloads: [LinkDownload] {
        items.compactMap { item in
            guard isIncluded(item.id) else { return nil }
            let name = name(of: item.id)
            switch item.kind {
            case .checking:
                return nil
            case .file(let url, _):
                return .file(url, name: name)
            case .page(let model):
                return model.draft.phase.isLooking ? nil : .file(model.draft.page.url, name: name)
            case .video(let model, let candidate):
                guard let version = model.draft.chosenVersion(of: candidate) else { return nil }
                return .media(page: model.draft.page, candidate: model.draft.candidates[candidate], version: version, name: name)
            }
        }
    }

    public var hasPages: Bool {
        entries.contains {
            switch $0.state {
            case .page, .waiting: true
            case .checking, .file: false
            }
        }
    }

    public var includedLine: String {
        let items = items
        return "\(items.filter { isIncluded($0.id) }.count) of \(items.count) included"
    }
}

extension SentPageDraft.Phase {
    var isLooking: Bool { self == .looking || self == .playing }
}
