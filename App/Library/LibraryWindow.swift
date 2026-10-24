import AppKit
import DowlioCore
import DowlioLibrary
import QuickLook
import SwiftUI

struct LibraryWindow: View {
    let model: AppModel
    @FocusState private var isFocused: Bool
    @State private var selection: DownloadID?
    @State private var confirmation: Confirmation?
    @State private var quickLookFile: URL?
    @SceneStorage("showsInspector") private var showsInspector = false
    @Environment(\.openWindow) private var openWindow

    private var actions: RowActions {
        RowActions(model: model) { confirmation = $0 }
    }

    private var selectedRow: DownloadRow? {
        selection.flatMap(model.row)
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 320)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onKeyPress(.space) {
                guard let file = selectedRow?.finishedFile else { return .ignored }
                quickLookFile = quickLookFile == nil ? file : nil
                return .handled
            }
            .onPasteCommand(of: [.url, .plainText]) { _ in
                let pasteboard = NSPasteboard.general
                if let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
                    model.add(pasted: text)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Clear Completed", systemImage: "checkmark.circle") { model.clearCompleted() }
                        .help("Clear Completed")
                        .disabled(!model.rows.contains { $0.state == .completed })
                }
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
                        .help(showsInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
            .inspector(isPresented: $showsInspector) {
                InspectorView(row: selectedRow, actions: actions)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .focusedSceneValue(\.selectedDownload, selectedRow.map {
                SelectedDownload(row: $0, actions: actions, quickLook: { quickLookFile = $0.finishedFile })
            })
            .quickLookPreview($quickLookFile)
            .alert(confirmation?.title ?? "", isPresented: isConfirming, presenting: confirmation) { pending in
                Button(pending.confirmTitle, role: .destructive) { actions.carryOut(pending) }
                Button(pending.dismissTitle, role: .cancel) {}
            } message: { pending in
                if !pending.message.isEmpty { Text(pending.message) }
            }
            .alert(model.actionFailure ?? "", isPresented: failureShown) {
                Button("OK") {}
            }
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem {
            ContentUnavailableView("Dowlio can't start", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if model.rows.isEmpty {
            ContentUnavailableView("No downloads yet", systemImage: "tray", description: Text("Paste a link with ⌘V."))
        } else {
            List(model.rows, selection: $selection) { row in
                DownloadRowView(row: row, actions: actions)
            }
            .contextMenu(forSelectionType: DownloadID.self) { ids in
                if let id = ids.first, let row = model.row(id) {
                    RowMenuItems(row: row, actions: actions) { quickLookFile = $0.finishedFile }
                }
            } primaryAction: { ids in
                for id in ids { openWindow(id: DetailWindow.sceneID, value: id) }
            }

        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })
    }
}
