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
    /// The New Download sheet, made once each time it's asked for and dropped when it closes.
    var newDownload: NewDownloadModel?
    /// Opens the library window. The window hands it over the first time it appears, so a link
    /// that arrives while it's closed can open it again.
    var openLibraryWindow: (() -> Void)?

    let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private(set) var freeSpace: Int64?

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
            MainActor.assumeIsolated {
                self?.perform { await $0.checkFinishedFiles() }
                self?.measureFreeSpace()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.measureFreeSpace()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func row(_ id: DownloadID) -> DownloadRow? {
        rows.first { $0.id == id }
    }

    /// Shows the New Download sheet with `text` in its link field, opening the window first. With
    /// the sheet already up, the links join it.
    func requestNewDownload(_ text: String = "") {
        openLibraryWindow?()
        if let newDownload {
            newDownload.append(text)
        } else if let library {
            newDownload = NewDownloadModel(text: text, folder: downloadsFolder) { url, options in
                try await library.inspect(url, options: options)
            }
        }
    }

    func add(_ draft: NewDownloadDraft) {
        let options = draft.options
        perform { library in
            for url in draft.links {
                await library.add(url, destination: .folder(draft.folder), options: options, startImmediately: draft.startImmediately)
            }
        }
    }

    func pause(_ row: DownloadRow) { perform { await $0.pause(row.id) } }
    func resume(_ row: DownloadRow) { perform { await $0.resume(row.id) } }
    func retry(_ row: DownloadRow) { perform { await $0.retry(row.id) } }
    func cancel(_ row: DownloadRow) { perform { await $0.cancel(row.id) } }
    func removeFromList(_ row: DownloadRow) { perform { await $0.removeFromList(row.id) } }
    func clearCompleted() { perform { await $0.clearCompleted() } }
    func pauseAll() { perform { await $0.pauseAll() } }
    func resumeAll() { perform { await $0.resumeAll() } }

    private func measureFreeSpace() {
        let values = try? downloadsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeSpace = values?.volumeAvailableCapacityForImportantUsage
    }

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
}
