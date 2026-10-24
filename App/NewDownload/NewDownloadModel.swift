import DowlioCore
import DowlioLibrary
import Foundation
import Observation

/// The New Download sheet's draft, with the checks it runs. The links count as soon as they're
/// typed. Checking them waits for typing to pause.
@MainActor
@Observable
final class NewDownloadModel: Identifiable {
    var draft: NewDownloadDraft {
        didSet {
            if draft.links != oldValue.links || draft.inspectionOptions != oldValue.inspectionOptions { scheduleChecks() }
        }
    }

    private let inspect: (URL, RequestOptions) async throws -> LinkInspection
    private var pending: Task<Void, Never>?

    init(text: String, folder: URL, inspect: @escaping (URL, RequestOptions) async throws -> LinkInspection) {
        draft = NewDownloadDraft(text: text, folder: folder)
        self.inspect = inspect
    }

    func append(_ more: String) {
        guard !more.isEmpty else { return }
        let current = draft.text.trimmingCharacters(in: .newlines)
        draft.text = current.isEmpty ? more : "\(current)\n\(more)"
    }

    /// Checks every link that needs it, now.
    func checkLinks() {
        pending?.cancel()
        let headers = draft.inspectionOptions
        for url in draft.linksToCheck() {
            Task { [weak self, inspect] in
                let check: NewDownloadDraft.Check
                do {
                    check = .inspected(try await inspect(url, headers))
                } catch let error as DownloadError {
                    check = .failed(error)
                } catch {
                    check = .failed(.network(NetworkFailure(error)))
                }
                self?.draft.record(check, for: url, checkedWith: headers)
            }
        }
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
