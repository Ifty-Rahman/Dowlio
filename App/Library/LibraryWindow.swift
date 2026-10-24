import AppKit
import DowlioCore
import DowlioLibrary
import QuickLook
import SwiftUI

struct LibraryWindow: View {
    static let sceneID = "library"

    let model: AppModel
    @FocusState private var isFocused: Bool
    @FocusState private var isSearching: Bool
    @State private var selection: DownloadID?
    @State private var confirmation: Confirmation?
    @State private var quickLookFile: URL?
    @State private var search = ""
    @SceneStorage("libraryFilter") private var filter = LibraryFilter.all
    @SceneStorage("showsInspector") private var showsInspector = false
    @Environment(\.openWindow) private var openWindow

    private var actions: RowActions {
        RowActions(model: model) { confirmation = $0 }
    }

    private var view: LibraryView {
        LibraryView(rows: model.rows, filter: filter, search: search)
    }

    private var selectedRow: DownloadRow? {
        selection.flatMap(model.row)
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(counts: view.counts, selection: $filter, freeSpace: model.freeSpace)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .navigationTitle(filter.title)
                .navigationSubtitle(view.summary)
                .searchable(text: $search, placement: .toolbar, prompt: "Search downloads")
                .modifier(SearchFocus(isFocused: $isSearching))
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    InspectorView(row: selectedRow, actions: actions)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        }
        .frame(minWidth: 760, minHeight: 420)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            model.openLibraryWindow = { [openWindow] in openWindow(id: LibraryWindow.sceneID) }
        }
        .onKeyPress(.space) {
            guard let file = selectedRow?.finishedFile else { return .ignored }
            quickLookFile = quickLookFile == nil ? file : nil
            return .handled
        }
        .onPasteCommand(of: [.url, .plainText]) { _ in
            let pasteboard = NSPasteboard.general
            model.requestNewDownload(pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.requestNewDownload(urls.map(\.absoluteString).joined(separator: "\n"))
            return true
        }
        .sheet(item: Bindable(model).newDownload) { sheet in
            NewDownloadSheet(sheet: sheet) { model.add($0) }
        }
        .focusedSceneValue(\.findInLibrary, FindInLibrary { isSearching = true })
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Clear Completed", systemImage: "checkmark.circle") { model.clearCompleted() }
                .help("Clear Completed")
                .disabled(!view.canClearCompleted)
            Button("New Download", systemImage: "plus") { model.requestNewDownload() }
                .help("New Download")
            Button("Resume All", systemImage: "play.fill") { model.resumeAll() }
                .help("Resume All")
                .disabled(!view.canResumeAll)
            Button("Pause All", systemImage: "pause.fill") { model.pauseAll() }
                .help("Pause All")
                .disabled(!view.canPauseAll)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
                .help(showsInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    @ViewBuilder private var detail: some View {
        if let problem = model.problem {
            ContentUnavailableView("Dowlio can't start", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if model.rows.isEmpty {
            ContentUnavailableView {
                Label("No downloads yet", systemImage: "tray")
            } description: {
                Text("Paste a link with ⌘V or drop one here.")
            } actions: {
                Button("New Download…") { model.requestNewDownload() }
            }
        } else if view.rows.isEmpty {
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(filter.emptyText, systemImage: filter.symbolName)
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            List(view.rows, selection: $selection) { row in
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

private struct LibrarySidebar: View {
    let counts: [LibraryFilter: Int]
    @Binding var selection: LibraryFilter
    let freeSpace: Int64?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let new = $0 { selection = new } })) {
            Section("Library") {
                ForEach(LibraryFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbolName)
                        .badge(counts[filter] ?? 0)
                        .tag(filter)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let freeSpace {
                Label(FreeSpaceText.string(freeSpace), systemImage: "internaldrive")
                    .font(DowlioDesign.TypeRole.detailMetric)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DowlioDesign.Spacing.sm)
                    .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
                    .padding(DowlioDesign.Spacing.sm)
            }
        }
    }
}

extension LibraryFilter {
    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .queued: "clock"
        case .failed: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        }
    }

    var emptyText: String {
        switch self {
        case .all: "No downloads yet"
        case .downloading: "Nothing is downloading"
        case .paused: "No paused downloads"
        case .queued: "No queued downloads"
        case .failed: "No failed downloads"
        case .completed: "No completed downloads"
        }
    }
}

/// Moves focus to the toolbar's search field. SwiftUI can do that only from macOS 15.
private struct SearchFocus: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused(isFocused)
        } else {
            content
        }
    }
}

struct FindInLibrary {
    let focusSearch: () -> Void
}

extension FocusedValues {
    @Entry var findInLibrary: FindInLibrary?
}

/// Edit › Find (⌘F) focuses the library window's search field.
struct FindCommands: Commands {
    @FocusedValue(\.findInLibrary) private var find

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { find?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
        }
    }
}
