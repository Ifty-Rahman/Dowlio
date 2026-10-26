import AppKit
import DowlioLibrary
import SwiftUI

/// A destructive or surprising action on one or more downloads, waiting for the user to confirm it.
enum Confirmation: Identifiable {
    case pauseStartsOver([DownloadRow])
    case cancel([DownloadRow])
    case removePartial([DownloadRow])
    case moveToTrash([DownloadRow])

    var id: String {
        switch self {
        case .pauseStartsOver(let rows): "pause-" + Self.key(rows)
        case .cancel(let rows): "cancel-" + Self.key(rows)
        case .removePartial(let rows): "remove-" + Self.key(rows)
        case .moveToTrash(let rows): "trash-" + Self.key(rows)
        }
    }

    private static func key(_ rows: [DownloadRow]) -> String {
        rows.map(\.id.description).joined(separator: ",")
    }
}

/// Every action on downloads, for one row or a whole selection, asking first where the spec says
/// to. The row button, the context menu, the Download menu, the toolbar and the inspector all go
/// through here.
@MainActor
struct RowActions {
    let model: AppModel
    let confirm: (Confirmation) -> Void

    func pause(_ rows: [DownloadRow]) {
        let pausable = SelectionSummary(rows: rows).pausable
        let startsOver = pausable.filter(\.pauseStartsOver)
        for row in pausable where !row.pauseStartsOver { model.pause(row) }
        if !startsOver.isEmpty { confirm(.pauseStartsOver(startsOver)) }
    }

    func resume(_ rows: [DownloadRow]) {
        for row in SelectionSummary(rows: rows).resumable { model.resume(row) }
    }

    func retry(_ rows: [DownloadRow]) {
        for row in SelectionSummary(rows: rows).retryable { model.retry(row) }
    }

    func showInFinder(_ rows: [DownloadRow]) {
        let files = SelectionSummary(rows: rows).finishedFiles
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    func open(_ rows: [DownloadRow]) {
        for file in SelectionSummary(rows: rows).finishedFiles { NSWorkspace.shared.open(file) }
    }

    func copyLinks(_ rows: [DownloadRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SelectionSummary(rows: rows).linksText, forType: .string)
    }

    func cancel(_ rows: [DownloadRow]) {
        let summary = SelectionSummary(rows: rows)
        if summary.removeAsksFirst { confirm(.cancel(summary.cancellable)) } else { summary.cancellable.forEach(model.cancel) }
    }

    func removeFromList(_ rows: [DownloadRow]) {
        if SelectionSummary(rows: rows).removeAsksFirst { confirm(.removePartial(rows)) } else { rows.forEach(model.removeFromList) }
    }

    func moveToTrash(_ rows: [DownloadRow]) {
        let finished = rows.filter { $0.finishedFile != nil }
        if !finished.isEmpty { confirm(.moveToTrash(finished)) }
    }

    func clearCompleted() { model.clearCompleted() }

    func pause(_ row: DownloadRow) { pause([row]) }
    func resume(_ row: DownloadRow) { resume([row]) }
    func retry(_ row: DownloadRow) { retry([row]) }
    func showInFinder(_ row: DownloadRow) { showInFinder([row]) }
    func copyLink(_ row: DownloadRow) { copyLinks([row]) }
    func cancel(_ row: DownloadRow) { cancel([row]) }

    func carryOut(_ confirmation: Confirmation) {
        switch confirmation {
        case .pauseStartsOver(let rows): rows.forEach(model.pause)
        case .cancel(let rows): rows.forEach(model.cancel)
        case .removePartial(let rows): rows.forEach(model.removeFromList)
        case .moveToTrash(let rows): rows.forEach(model.moveToTrash)
        }
    }
}

extension Confirmation {
    private var rows: [DownloadRow] {
        switch self {
        case .pauseStartsOver(let rows), .cancel(let rows), .removePartial(let rows), .moveToTrash(let rows): rows
        }
    }

    var title: String {
        let summary = SelectionSummary(rows: rows)
        return switch self {
        case .pauseStartsOver:
            rows.count == 1
                ? "This server can't resume. Pausing starts it over from the beginning."
                : "\(rows.count) of these servers can't resume. Pausing starts those downloads over from the beginning."
        case .cancel: summary.cancelQuestion
        case .removePartial: summary.removeQuestion
        case .moveToTrash: summary.trashQuestion
        }
    }

    var message: String {
        switch self {
        case .pauseStartsOver: ""
        case .cancel, .removePartial: SelectionSummary(rows: rows).lossWarning ?? ""
        case .moveToTrash: "You can put them back from the Trash."
        }
    }

    var confirmTitle: String {
        switch self {
        case .pauseStartsOver: "Pause"
        case .cancel: rows.count == 1 ? "Cancel Download" : "Cancel Downloads"
        case .removePartial: "Remove"
        case .moveToTrash: "Move to Trash"
        }
    }

    var dismissTitle: String {
        switch self {
        case .pauseStartsOver: "Keep Downloading"
        case .cancel, .removePartial: rows.count == 1 ? "Keep It" : "Keep Them"
        case .moveToTrash: "Cancel"
        }
    }
}

/// The context menu and Download menu items for the selected downloads.
struct SelectionMenuItems: View {
    let rows: [DownloadRow]
    let actions: RowActions
    var quickLook: (() -> Void)?

    var body: some View {
        let summary = SelectionSummary(rows: rows)
        Button(summary.pauseTitle) { actions.pause(rows) }
            .disabled(summary.pausable.isEmpty)
        Button(summary.resumeTitle) { actions.resume(rows) }
            .disabled(summary.resumable.isEmpty)
        Button(summary.retryTitle) { actions.retry(rows) }
            .disabled(summary.retryable.isEmpty)
        Divider()
        Button("Show in Finder") { actions.showInFinder(rows) }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(summary.finishedFiles.isEmpty)
        Button("Open") { actions.open(rows) }
            .disabled(summary.finishedFiles.isEmpty)
        Button("Quick Look") { quickLook?() }
            .disabled(summary.finishedFiles.isEmpty || quickLook == nil)
        Button(summary.copyLinksTitle) { actions.copyLinks(rows) }
        Divider()
        Button(summary.cancelTitle, role: .destructive) { actions.cancel(rows) }
            .disabled(summary.cancellable.isEmpty)
        Button(summary.removeTitle) { actions.removeFromList(rows) }
            .keyboardShortcut(.delete, modifiers: .command)
        Button("Move to Trash…", role: .destructive) { actions.moveToTrash(rows) }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(summary.finishedFiles.isEmpty)
        Divider()
        Button("Clear Completed") { actions.clearCompleted() }
    }
}

struct SelectedDownloads {
    let rows: [DownloadRow]
    let actions: RowActions
    let quickLook: () -> Void
}

extension FocusedValues {
    @Entry var selectedDownloads: SelectedDownloads?
}

/// The Download menu, acting on the selected downloads in the library window.
struct DownloadCommands: Commands {
    let model: AppModel
    @FocusedValue(\.selectedDownloads) private var selected

    var body: some Commands {
        CommandMenu("Download") {
            let library = LibraryView(rows: model.rows, selection: .filter(.all), search: "")
            Button("Pause All") { model.pauseAll() }
                .keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(!library.canPauseAll)
            Button("Resume All") { model.resumeAll() }
                .disabled(!library.canResumeAll)
            Divider()
            if let selected, !selected.rows.isEmpty {
                SelectionMenuItems(rows: selected.rows, actions: selected.actions, quickLook: selected.quickLook)
            } else {
                Button("Show in Finder") {}.keyboardShortcut("r", modifiers: .command).disabled(true)
                Button("Remove from List") {}.keyboardShortcut(.delete, modifiers: .command).disabled(true)
                Button("Move to Trash…") {}.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(true)
            }
        }
    }
}
