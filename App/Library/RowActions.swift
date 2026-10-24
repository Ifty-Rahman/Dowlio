import DowlioLibrary
import SwiftUI

/// A destructive or surprising action, waiting for the user to confirm it.
enum Confirmation: Identifiable {
    case pauseStartsOver(DownloadRow)
    case cancel(DownloadRow)
    case removePartial(DownloadRow)
    case moveToTrash(DownloadRow)

    var id: String {
        switch self {
        case .pauseStartsOver(let row): "pause-\(row.id)"
        case .cancel(let row): "cancel-\(row.id)"
        case .removePartial(let row): "remove-\(row.id)"
        case .moveToTrash(let row): "trash-\(row.id)"
        }
    }
}

/// Every action on one download, asking first where the spec says to. The row button, the context
/// menu, the Download menu and the inspector all go through here.
@MainActor
struct RowActions {
    let model: AppModel
    let confirm: (Confirmation) -> Void

    func pause(_ row: DownloadRow) {
        if row.pauseStartsOver { confirm(.pauseStartsOver(row)) } else { model.pause(row) }
    }

    func resume(_ row: DownloadRow) { model.resume(row) }
    func retry(_ row: DownloadRow) { model.retry(row) }
    func showInFinder(_ row: DownloadRow) { model.showInFinder(row) }
    func open(_ row: DownloadRow) { model.open(row) }
    func copyLink(_ row: DownloadRow) { model.copyLink(row) }
    func cancel(_ row: DownloadRow) {
        if row.hasBytesAtStake { confirm(.cancel(row)) } else { model.cancel(row) }
    }

    func clearCompleted() { model.clearCompleted() }
    func moveToTrash(_ row: DownloadRow) { confirm(.moveToTrash(row)) }

    func removeFromList(_ row: DownloadRow) {
        if row.hasBytesAtStake { confirm(.removePartial(row)) } else { model.removeFromList(row) }
    }

    func carryOut(_ confirmation: Confirmation) {
        switch confirmation {
        case .pauseStartsOver(let row): model.pause(row)
        case .cancel(let row), .removePartial(let row): model.cancel(row)
        case .moveToTrash(let row): model.moveToTrash(row)
        }
    }
}

extension Confirmation {
    var title: String {
        switch self {
        case .pauseStartsOver: "This server can't resume. Pausing starts it over from the beginning."
        case .cancel: "Cancel this download?"
        case .removePartial(let row): "Remove “\(row.fileName)” from the list?"
        case .moveToTrash(let row): "Move “\(row.fileName)” to the Trash?"
        }
    }

    var message: String {
        switch self {
        case .pauseStartsOver: ""
        case .cancel(let row), .removePartial(let row):
            "The \(ByteText.string(row.receivedBytes)) downloaded so far will be deleted."
        case .moveToTrash: "You can put it back from the Trash."
        }
    }

    var confirmTitle: String {
        switch self {
        case .pauseStartsOver: "Pause"
        case .cancel: "Cancel Download"
        case .removePartial: "Remove"
        case .moveToTrash: "Move to Trash"
        }
    }

    var dismissTitle: String {
        switch self {
        case .pauseStartsOver: "Keep Downloading"
        case .cancel, .removePartial: "Keep It"
        case .moveToTrash: "Cancel"
        }
    }
}

struct RowMenuItems: View {
    let row: DownloadRow
    let actions: RowActions
    var quickLook: ((DownloadRow) -> Void)?

    var body: some View {
        if row.canPause {
            Button("Pause") { actions.pause(row) }
        } else if row.state == .paused {
            Button("Resume") { actions.resume(row) }
        } else if case .failed = row.state {
            Button("Retry") { actions.retry(row) }
        }
        Divider()
        Button("Show in Finder") { actions.showInFinder(row) }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(row.finishedFile == nil)
        Button("Open") { actions.open(row) }
            .disabled(row.finishedFile == nil)
        Button("Quick Look") { quickLook?(row) }
            .disabled(row.finishedFile == nil || quickLook == nil)
        Button("Copy Link") { actions.copyLink(row) }
        Divider()
        if row.canCancel {
            Button("Cancel Download…", role: .destructive) { actions.cancel(row) }
        }
        Button(row.hasBytesAtStake ? "Remove from List…" : "Remove from List") { actions.removeFromList(row) }
            .keyboardShortcut(.delete, modifiers: .command)
        Button("Move to Trash…", role: .destructive) { actions.moveToTrash(row) }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(row.finishedFile == nil)
        Divider()
        Button("Clear Completed") { actions.clearCompleted() }
    }
}

struct SelectedDownload {
    let row: DownloadRow
    let actions: RowActions
    let quickLook: (DownloadRow) -> Void
}

extension FocusedValues {
    @Entry var selectedDownload: SelectedDownload?
}

/// The Download menu, acting on the selected download in the library window.
struct DownloadCommands: Commands {
    let model: AppModel
    @FocusedValue(\.selectedDownload) private var selected

    var body: some Commands {
        CommandMenu("Download") {
            let library = LibraryView(rows: model.rows, selection: .filter(.all), search: "")
            Button("Pause All") { model.pauseAll() }
                .keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(!library.canPauseAll)
            Button("Resume All") { model.resumeAll() }
                .disabled(!library.canResumeAll)
            Divider()
            if let selected {
                RowMenuItems(row: selected.row, actions: selected.actions, quickLook: selected.quickLook)
            } else {
                Button("Show in Finder") {}.keyboardShortcut("r", modifiers: .command).disabled(true)
                Button("Remove from List") {}.keyboardShortcut(.delete, modifiers: .command).disabled(true)
                Button("Move to Trash…") {}.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(true)
            }
        }
    }
}
