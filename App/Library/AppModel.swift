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
    /// A failed action to tell the user about, such as a file the Trash refused.
    var actionFailure: String?

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
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform { await $0.checkFinishedFiles() } }
        }
    }

    func row(_ id: DownloadID) -> DownloadRow? {
        rows.first { $0.id == id }
    }

    /// Adds the first `http` or `https` link in `text` with the default settings, into Downloads.
    func add(pasted text: String) {
        guard let url = Self.firstLink(in: text) else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        perform { await $0.add(url, destination: .folder(downloads)) }
    }

    func pause(_ row: DownloadRow) { perform { await $0.pause(row.id) } }
    func resume(_ row: DownloadRow) { perform { await $0.resume(row.id) } }
    func retry(_ row: DownloadRow) { perform { await $0.retry(row.id) } }
    func cancel(_ row: DownloadRow) { perform { await $0.cancel(row.id) } }
    func removeFromList(_ row: DownloadRow) { perform { await $0.removeFromList(row.id) } }
    func clearCompleted() { perform { await $0.clearCompleted() } }

    func moveToTrash(_ row: DownloadRow) {
        perform { [weak self] library in
            do {
                try await library.moveToTrash(row.id)
            } catch {
                self?.actionFailure = "Dowlio couldn't move “\(row.fileName)” to the Trash. \(error.localizedDescription)"
            }
        }
    }

    func showInFinder(_ row: DownloadRow) {
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func open(_ row: DownloadRow) {
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.open(file)
    }

    func copyLink(_ row: DownloadRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.sourceURL.absoluteString, forType: .string)
    }

    private func perform(_ work: @escaping @MainActor (Library) async -> Void) {
        guard let library else { return }
        Task { await work(library) }
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
