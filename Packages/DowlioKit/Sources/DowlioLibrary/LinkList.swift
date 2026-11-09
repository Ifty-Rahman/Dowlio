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
    case playlist(page: SentPage, listing: PlaylistListing, entries: [PlaylistListing.Entry], showing: SentPageDraft.Showing, quality: VideoQuality)
}

@MainActor
@Observable
public final class LinkList {
    private enum State {
        case checking
        case file(URL, NewDownloadDraft.Check?)
        case page(SentPageModel)
    }

    private struct Entry {
        let id: Int
        let url: URL
        var options: RequestOptions
        var state: State
        var included = false
        var pageIncluded = false
        var analysis: Task<Void, Never>?
    }

    private var entry: Entry?
    private var nextID = 0
    private var currentID: LinkItem.ID?
    private var lastPosition = 0
    private var names: [LinkItem.ID: (name: String, version: Version?)] = [:]
    @ObservationIgnored private let analyze: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let lookAgain: (SentPage) -> AsyncStream<PageAnalysis>
    @ObservationIgnored private let probe: (SentPage, Candidate) async -> Candidate
    @ObservationIgnored private let preference: () -> QualityPreference
    @ObservationIgnored private let tools: ToolConsent?

    public init(
        analyze: @escaping (SentPage) -> AsyncStream<PageAnalysis>,
        lookAgain: @escaping (SentPage) -> AsyncStream<PageAnalysis> = { _ in .nothingFound },
        probe: @escaping (SentPage, Candidate) async -> Candidate = { $1 },
        preference: @escaping () -> QualityPreference = { QualityPreference() },
        tools: ToolConsent? = nil
    ) {
        self.tools = tools
        self.analyze = analyze
        self.lookAgain = lookAgain
        self.probe = probe
        self.preference = preference
    }

    public func update(link: URL?, options: RequestOptions = RequestOptions()) {
        guard let link else { return clear() }
        if entry?.url == link {
            entry?.options = options
            return
        }
        replace(with: makeEntry(link, options: options, state: .checking))
    }

    public func checked(_ url: URL, _ check: NewDownloadDraft.Check) {
        guard let current = entry, current.url == url else { return }
        switch current.state {
        case .checking, .file:
            if Self.mayBeAPage(check) {
                let page = SentPage(url: url, cookies: current.options.cookies, userAgent: current.options.userAgent)
                startAnalysing(makeModel(page))
            } else {
                entry?.state = .file(url, check)
            }
        case .page:
            break
        }
    }

    private static func mayBeAPage(_ check: NewDownloadDraft.Check) -> Bool {
        switch check {
        case .inspected(let inspection): inspection.isWebPage
        case .failed(.network(let failure)): failure.code == .badServerResponse
        case .checking, .failed: false
        }
    }

    /// Analyses a page sent from the browser in place of whatever the list held.
    public func send(_ page: SentPage) {
        replace(with: makeEntry(page.url, options: RequestOptions(), state: .checking))
        startAnalysing(makeModel(page))
    }

    public func clear() {
        if let entry { stop(entry) }
        entry = nil
        names = [:]
        currentID = nil
        lastPosition = 0
    }

    private func replace(with new: Entry) {
        clear()
        entry = new
    }

    private func makeEntry(_ url: URL, options: RequestOptions, state: State) -> Entry {
        nextID += 1
        return Entry(id: nextID, url: url, options: options, state: state)
    }

    private func makeModel(_ page: SentPage) -> SentPageModel {
        SentPageModel(page: page, preference: preference(), playPage: lookAgain, analyzePage: analyze, tools: tools, probe: probe)
    }

    private func stop(_ entry: Entry) {
        entry.analysis?.cancel()
        if case .page(let model) = entry.state { model.stop() }
    }

    private func startAnalysing(_ model: SentPageModel) {
        guard let id = entry?.id else { return }
        let updates = analyze(model.draft.page)
        entry?.state = .page(model)
        entry?.analysis = Task { [weak self] in
            let file = await model.follow(updates)
            guard !Task.isCancelled else { return }
            self?.finished(id, handingBack: file)
        }
    }

    private func finished(_ id: Int, handingBack file: URL?) {
        guard entry?.id == id else { return }
        entry?.analysis = nil
        if let file { entry?.state = .file(file, nil) }
    }

    public var items: [LinkItem] {
        guard let entry else { return [] }
        switch entry.state {
        case .checking:
            return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .checking(entry.url))]
        case .file(let url, let check):
            return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .file(url, check))]
        case .page(let model):
            switch model.draft.phase {
            case .found, .restricted:
                return model.draft.candidates.indices.map { LinkItem(id: .init(entry: entry.id, candidate: $0), kind: .video(model, $0)) }
            default:
                return [LinkItem(id: .init(entry: entry.id, candidate: nil), kind: .page(model))]
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

    public func showLink(_ url: URL) {
        guard let entry, entry.url == url else { return }
        currentID = LinkItem.ID(entry: entry.id, candidate: nil)
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
        return model.draft.selectedVersions(of: candidate).first
    }

    public func isIncluded(_ id: LinkItem.ID) -> Bool {
        guard let entry, entry.id == id.entry else { return false }
        if items.count == 1 { return isDownloadedAlone(entry, candidate: id.candidate) }
        switch entry.state {
        case .checking, .file:
            return entry.included
        case .page(let model):
            if let candidate = id.candidate {
                let restricted = model.draft.candidates.indices.contains(candidate) && model.draft.candidates[candidate].restriction != nil
                return !restricted && model.draft.isIncluded(candidate)
            }
            return model.draft.phase.isLooking ? entry.included : entry.pageIncluded
        }
    }

    private func isDownloadedAlone(_ entry: Entry, candidate: Int?) -> Bool {
        switch entry.state {
        case .checking, .file:
            return true
        case .page(let model):
            guard let candidate else { return model.draft.phase.isLooking || model.draft.phase == .playlist }
            return model.draft.candidates.indices.contains(candidate) && model.draft.candidates[candidate].restriction == nil
        }
    }

    public func include(_ id: LinkItem.ID, _ included: Bool) {
        guard let state = entry?.state, entry?.id == id.entry else { return }
        switch state {
        case .checking, .file:
            entry?.included = included
        case .page(let model):
            if let candidate = id.candidate {
                model.include(candidate, included)
            } else if model.draft.phase.isLooking {
                entry?.included = included
            } else {
                entry?.pageIncluded = included
            }
        }
    }

    public var includesAll: Bool {
        let videos = items.filter(\.isOpenToInclude)
        return !videos.isEmpty && videos.allSatisfy { isIncluded($0.id) }
    }

    public func includeAll(_ included: Bool) {
        for item in items where item.isOpenToInclude { include(item.id, included) }
    }

    public func name(of id: LinkItem.ID) -> String? {
        name(of: id, version: chosenVersion(of: id))
    }

    private func name(of id: LinkItem.ID, version: Version?) -> String? {
        guard let named = names[id], named.version == version else { return nil }
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
        items.flatMap { item -> [LinkDownload] in
            guard isIncluded(item.id) else { return [] }
            let name = name(of: item.id)
            switch item.kind {
            case .checking:
                return []
            case .file(let url, _):
                return [.file(url, name: name)]
            case .page(let model):
                if model.draft.phase == .playlist, let listing = model.draft.playlist {
                    let entries = model.draft.includedEntries
                    guard !entries.isEmpty else { return [] }
                    return [.playlist(
                        page: model.draft.page, listing: listing, entries: entries, showing: model.draft.playlistShowing,
                        quality: model.draft.playlistQuality
                    )]
                }
                return model.draft.phase.isLooking ? [] : [.file(model.draft.page.url, name: name)]
            case .video(let model, let candidate):
                return model.draft.selectedVersions(of: candidate).map { version in
                    .media(page: model.draft.page, candidate: model.draft.candidates[candidate], version: version, name: self.name(of: item.id, version: version))
                }
            }
        }
    }

    public var hasPages: Bool {
        if case .page = entry?.state { true } else { false }
    }

    public var includedLine: String {
        let items = items
        return "\(items.filter { isIncluded($0.id) }.count) of \(items.count) included"
    }
}

extension LinkItem {
    @MainActor public var isOpenToInclude: Bool {
        guard case .video(let model, let candidate) = kind else { return false }
        return model.draft.candidates[candidate].restriction == nil
    }
}

extension SentPageDraft.Phase {
    var isLooking: Bool { self == .looking || self == .playing }
}
