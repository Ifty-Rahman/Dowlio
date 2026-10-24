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
    /// The New Download sheet waiting to show, with the links it opens with.
    var newDownload: NewDownloadRequest?
    /// Opens the library window. The window hands it over the first time it appears, so a link
    /// that arrives while it's closed can open it again.
    var openLibraryWindow: (() -> Void)?

    let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

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
        IncomingLinks.shared.deliver { [weak self] urls in
            self?.requestNewDownload(urls.map(\.absoluteString).joined(separator: "\n"))
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform { await $0.checkFinishedFiles() } }
        }
    }

    func row(_ id: DownloadID) -> DownloadRow? {
        rows.first { $0.id == id }
    }

    /// The New Download sheet on screen, so links that arrive while it's open join it.
    weak var openSheet: NewDownloadModel?

    /// Shows the New Download sheet with `text` in its link field, opening the window first. With
    /// the sheet already open, the links join it.
    func requestNewDownload(_ text: String = "") {
        openLibraryWindow?()
        if let openSheet {
            openSheet.append(text)
        } else if let waiting = newDownload {
            newDownload = NewDownloadRequest(text: [waiting.text, text].filter { !$0.isEmpty }.joined(separator: "\n"))
        } else {
            newDownload = NewDownloadRequest(text: text)
        }
    }

    func add(_ links: [URL], into folder: URL, options: RequestOptions, startImmediately: Bool) {
        perform { library in
            for url in links {
                await library.add(url, destination: .folder(folder), options: options, startImmediately: startImmediately)
            }
        }
    }

    func inspect(_ url: URL, options: RequestOptions) async throws -> LinkInspection {
        guard let library else { throw DownloadError.network(NetworkFailure(code: .unknown, message: "Dowlio can't start.")) }
        return try await library.inspect(url, options: options)
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
}

struct NewDownloadRequest: Identifiable {
    let id = UUID()
    let text: String
}

/// Links macOS hands to Dowlio from outside, such as one dropped on the Dock icon. They wait here
/// until the model is ready for them.
@MainActor
final class IncomingLinks {
    static let shared = IncomingLinks()

    private var waiting: [URL] = []
    private var handler: (([URL]) -> Void)?

    func receive(_ urls: [URL]) {
        guard let handler else { return waiting.append(contentsOf: urls) }
        handler(urls)
    }

    func deliver(to handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        if !waiting.isEmpty {
            handler(waiting)
            waiting = []
        }
    }
}
