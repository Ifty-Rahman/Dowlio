import AppKit
import DowlioCore
import DowlioEngine
import DowlioLibrary
import DowlioStore
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var rows: [DownloadRow] = []
    private(set) var problem: String?

    private let library: Library?

    init() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: AppIdentity.supportFolderName, directoryHint: .isDirectory)
            let store = try DownloadStore(databaseAt: support.appending(path: "Dowlio.sqlite"))
            library = Library(engine: DownloadEngine(), store: store)
        } catch {
            library = nil
            problem = "Dowlio can't open its history: \(error.localizedDescription)"
            return
        }
        Task { await follow() }
    }

    /// Adds the first `http` or `https` link in `text` with the default settings, into Downloads.
    func add(pasted text: String) {
        guard let library, let url = Self.firstLink(in: text) else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Task { await library.add(url, destination: .folder(downloads)) }
    }

    func pause(_ row: DownloadRow) {
        guard let library else { return }
        Task { await library.pause(row.id) }
    }

    func resume(_ row: DownloadRow) {
        guard let library else { return }
        Task { await library.resume(row.id) }
    }

    func retry(_ row: DownloadRow) {
        guard let library else { return }
        Task { await library.retry(row.id) }
    }

    func showInFinder(_ row: DownloadRow) {
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func follow() async {
        guard let library else { return }
        await library.start()
        for await rows in await library.rows() {
            self.rows = rows
        }
    }

    private static func firstLink(in text: String) -> URL? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .first { ["http", "https"].contains($0.scheme?.lowercased()) && $0.host() != nil }
    }
}
