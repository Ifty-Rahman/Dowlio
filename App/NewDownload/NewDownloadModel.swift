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
            if let page = media?.draft.page.url, draft.links != [page] { sentPages.clear() }
            if draft.links != oldValue.links || draft.links.map(draft.inspectionOptions(for:)) != oldValue.links.map(oldValue.inspectionOptions(for:)) {
                scheduleChecks()
            }
        }
    }

    let sentPages: SentPageHost
    private let inspect: (URL, RequestOptions) async throws -> LinkInspection
    private var pending: Task<Void, Never>?
    init(
        text: String,
        folder: URL,
        sentPages: SentPageHost,
        inspect: @escaping (URL, RequestOptions) async throws -> LinkInspection
    ) {
        draft = NewDownloadDraft(text: text, folder: folder)
        self.sentPages = sentPages
        self.inspect = inspect
    }

    var media: SentPageModel? { sentPages.current }

    func addSent(_ link: SentLink) {
        draft.addSent(link.url, referrer: link.referrer, cookies: link.cookies, browser: link.browser, userAgent: link.userAgent)
    }

    func discardSentPage() {
        sentPages.clear()
    }
    var showing = SentPageDraft.Showing.video {
        didSet {
            guard let media, showing != oldValue, let first = media.draft.versions(showing: showing).first else { return }
            media.pick(first)
        }
    }
    private var namedFile: (version: Version, name: String)?

    var mediaFileName: String {
        get {
            guard let media, let candidate = media.draft.selectedCandidate, let version = media.draft.chosenVersion else { return "" }
            if let namedFile, namedFile.version == version { return namedFile.name }
            return SentPageDraft.fileName(for: candidate, version: version)
        }
        set {
            guard let version = media?.draft.chosenVersion else { return }
            namedFile = (version, newValue)
        }
    }

    var chosenFileName: String? {
        guard let namedFile, namedFile.version == media?.draft.chosenVersion else { return nil }
        let name = namedFile.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    var canDownload: Bool {
        guard let media else { return draft.canDownload }
        switch media.draft.phase {
        case .looking: return false
        case .found: return !media.draft.downloads.isEmpty
        case .nothingFound: return draft.canDownload
        }
    }

    func append(_ more: String) {
        draft.append(more)
    }

    func analyze(_ page: SentPage) {
        sentPages.clear()
        draft.text = ""
        draft.addSent(page.url, referrer: nil, cookies: page.cookies, browser: page.browser, userAgent: page.userAgent)
        sentPages.send(page)
    }

    /// Checks every link that needs it, now.
    func checkLinks() {
        pending?.cancel()
        for url in draft.linksToCheck() {
            let headers = draft.inspectionOptions(for: url)
            Task { [weak self, inspect] in
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

    private func record(_ check: NewDownloadDraft.Check, for url: URL, checkedWith headers: RequestOptions) {
        draft.record(check, for: url, checkedWith: headers)
        guard draft.webPageToAnalyse == url, media?.draft.page.url != url else { return }
        sentPages.send(SentPage(url: url, cookies: headers.cookies, userAgent: headers.userAgent))
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
