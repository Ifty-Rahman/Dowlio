import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Observation

/// The New Download sheet's draft, with the checks it runs. The links count as soon as they're
/// typed. Checking them waits for typing to pause.
@MainActor
@Observable
final class NewDownloadModel: Identifiable {
    var draft: NewDownloadDraft {
        didSet {
            if draft.text != oldValue.text, !draft.text.isEmpty { frontPage = nil }
            if draft.links != oldValue.links || draft.links.map(draft.inspectionOptions(for:)) != oldValue.links.map(oldValue.inspectionOptions(for:)) {
                list.update(links: draft.links, options: draft.inspectionOptions(for:))
                scheduleChecks()
            }
        }
    }

    let list: LinkList
    private let inspect: (URL, RequestOptions) async throws -> LinkInspection
    private let signIn: (URL) async -> SiteSignIn?
    private var askedSignIn: Set<URL> = []
    private var pending: Task<Void, Never>?
    init(
        text: String,
        folder: URL,
        list: LinkList,
        inspect: @escaping (URL, RequestOptions) async throws -> LinkInspection,
        signIn: @escaping (URL) async -> SiteSignIn? = { _ in nil }
    ) {
        draft = NewDownloadDraft(text: text, folder: folder)
        self.list = list
        self.inspect = inspect
        list.update(links: draft.links, options: draft.inspectionOptions(for:))
    }

    private(set) var frontPage: FrontPageState?
    private var frontPageAsk: UUID?

    var isEmpty: Bool {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && list.items.isEmpty && frontPage == nil
    }

    func askFrontPage(of browser: String) -> UUID {
        frontPage = .asking(browser)
        let ask = UUID()
        frontPageAsk = ask
        return ask
    }

    func couldntRead(_ reason: CouldntRead, asked ask: UUID) {
        guard case .asking = frontPage, frontPageAsk == ask else { return }
        frontPage = .couldntRead(reason)
    }

    func useClipboard(_ text: String?) -> Bool {
        guard let link = ClipboardLink.first(in: text) else { return false }
        draft.append(link.absoluteString)
        frontPage = nil
        return true
    }

    func addSent(_ link: SentLink) {
        draft.addSent(link.url, referrer: link.referrer, cookies: link.cookies, browser: link.browser, userAgent: link.userAgent)
        list.showLink(link.url)
    }

    func discardSentPage() {
        frontPage = nil
        list.clear()
    }

    var makesDefaultQuality = false

    func fileName(of item: LinkItem) -> String {
        list.name(of: item.id) ?? suggestedName(of: item)
    }

    func rename(_ item: LinkItem, to name: String) {
        list.rename(item.id, name == suggestedName(of: item) ? "" : name)
    }

    private func suggestedName(of item: LinkItem) -> String {
        switch item.kind {
        case .checking(let url), .file(let url, _):
            if case .inspected(let inspection) = draft.check(for: url) { return inspection.fileName }
            return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case .page(let page):
            if case .inspected(let inspection) = draft.check(for: page.draft.page.url) { return inspection.fileName }
            return page.draft.host
        case .video(let page, let index):
            guard let version = list.chosenVersion(of: item.id) else { return "" }
            let addsResolution = AppModel.currentSettings().nameConflictPolicy == .keepBoth
            return MediaNaming.fileName(
                label: page.draft.candidates[index].label, version: version, addsResolution: addsResolution, isTaken: AppModel.nameIsTaken(in: draft.folder)
            )
        }
    }

    var canDownload: Bool {
        !list.isWaiting && !list.downloads.isEmpty
    }

    var downloadTitle: String {
        let count = list.downloads.count
        if count > 1 { return "Download \(count)" }
        return draft.downloadsAnyway && list.items.count == 1 ? "Download Anyway" : "Download"
    }

    func append(_ more: String) {
        draft.append(more)
    }

    func analyze(_ page: SentPage) {
        frontPage = nil
        draft.addSent(page.url, referrer: nil, cookies: page.cookies, browser: page.browser, userAgent: page.userAgent)
        list.send(page)
    }

    /// Checks every link that needs it, now.
    func checkLinks() {
        pending?.cancel()
        for url in draft.linksToCheck() {
            let headers = draft.inspectionOptions(for: url)
            Task { [weak self, inspect] in
                if await self?.borrowsSignIn(for: url, checkedWith: headers) == true { return }
                let check: NewDownloadDraft.Check
                do {
                    check = .inspected(try await inspect(url, headers))
                } catch let error as DownloadError {
                    check = .failed(error)
                } catch {
                    check = .failed(.network(NetworkFailure(error)))
                }
                self?.record(check, for: url, checkedWith: headers)
            }
        }
    }

    private func borrowsSignIn(for url: URL, checkedWith headers: RequestOptions) async -> Bool {
        guard headers.cookies.isEmpty, draft.origin(for: url) == nil, askedSignIn.insert(url).inserted,
              let found = await signIn(url), !found.cookies.isEmpty else { return false }
        draft.addSignIn(for: url, cookies: found.cookies, userAgent: found.userAgent)
        return true
    }

    private func record(_ check: NewDownloadDraft.Check, for url: URL, checkedWith headers: RequestOptions) {
        draft.record(check, for: url, checkedWith: headers)
        guard draft.check(for: url) == check else { return }
        list.checked(url, check)
    }

    private func scheduleChecks() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.checkLinks()
        }
    }
}
