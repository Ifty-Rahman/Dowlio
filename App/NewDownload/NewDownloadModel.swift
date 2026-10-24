import DowlioCore
import DowlioLibrary
import Foundation
import Observation

/// What the New Download sheet holds while the user fills it in. Each new link is inspected a
/// moment after typing stops.
@MainActor
@Observable
final class NewDownloadModel {
    enum Check: Equatable {
        case checking
        case inspected(LinkInspection)
        case failed(DownloadError)

        var status: LinkStatus {
            switch self {
            case .checking: .checking
            case .inspected(let inspection): LinkStatus(inspection)
            case .failed(let error): LinkStatus(failure: error)
            }
        }
    }

    var text: String {
        didSet { scheduleCheck() }
    }

    var folder: URL
    var connections = 8
    var referrer = ""
    var userAgent = ""
    var startImmediately = true
    /// The editable name, for a single link only.
    var fileName = ""

    private(set) var lines: [PastedLinks.Line] = []
    private(set) var checks: [URL: Check] = [:]

    private let inspect: (URL, RequestOptions) async throws -> LinkInspection
    private var pending: Task<Void, Never>?
    private var nameWasEdited = false

    init(text: String, folder: URL, inspect: @escaping (URL, RequestOptions) async throws -> LinkInspection) {
        self.text = text
        self.folder = folder
        self.inspect = inspect
        lines = PastedLinks.parse(text)
        startChecks()
    }

    var links: [URL] {
        lines.compactMap { if case .link(let url) = $0 { url } else { nil } }
    }

    var isSingleLink: Bool { links.count == 1 }

    var canDownload: Bool { !links.isEmpty }

    /// Some link couldn't be inspected, so Download means "download anyway".
    var downloadsAnyway: Bool {
        links.contains { if case .failed = checks[$0] { true } else { false } }
    }

    /// Why Download is unavailable, once the field has text.
    var explanation: String? {
        guard links.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Paste an http or https link, one per line."
    }

    /// Adds `more` links below the ones already in the field.
    func append(_ more: String) {
        guard !more.isEmpty else { return }
        let current = text.trimmingCharacters(in: .newlines)
        text = current.isEmpty ? more : "\(current)\n\(more)"
    }

    func nameEdited(_ name: String) {
        fileName = name
        nameWasEdited = true
    }

    var options: RequestOptions {
        var options = RequestOptions()
        options.connections = connections
        options.referrer = URL(string: referrer.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
        let agent = userAgent.trimmingCharacters(in: .whitespaces)
        options.userAgent = agent.isEmpty ? nil : agent
        if isSingleLink, nameWasEdited {
            let name = fileName.trimmingCharacters(in: .whitespaces)
            options.fileName = name.isEmpty ? nil : name
        }
        return options
    }

    private func scheduleCheck() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            lines = PastedLinks.parse(text)
            startChecks()
        }
    }

    private func startChecks() {
        let current = Set(links)
        checks = checks.filter { current.contains($0.key) }
        for url in links where checks[url] == nil {
            checks[url] = .checking
            let options = options
            Task { [weak self, inspect] in
                let check: Check
                do {
                    check = .inspected(try await inspect(url, options))
                } catch let error as DownloadError {
                    check = .failed(error)
                } catch {
                    check = .failed(.network(NetworkFailure(error)))
                }
                self?.finish(url, with: check)
            }
        }
    }

    private func finish(_ url: URL, with check: Check) {
        guard checks[url] != nil else { return }
        checks[url] = check
        if isSingleLink, links.first == url, !nameWasEdited, case .inspected(let inspection) = check {
            fileName = inspection.fileName
        }
    }
}
