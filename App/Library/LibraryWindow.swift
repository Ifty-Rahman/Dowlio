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
    @State private var selection = RowSelection()
    @State private var confirmation: Confirmation?
    @State private var quickLookFile: URL?
    @State private var search = ""
    @AppStorage("librarySelection") private var selectionInSidebar = LibrarySelection.filter(.all)
    @AppStorage("showsInspector") private var showsInspector = false
    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage(SettingsKey.hasSeenWelcome) private var hasSeenWelcome = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var actions: RowActions {
        RowActions(model: model) { confirmation = $0 }
    }

    private var view: LibraryView {
        LibraryView(rows: model.rows, selection: selectionInSidebar, search: search)
    }

    private var selectedRows: [DownloadRow] {
        view.rows.filter { selection.contains($0.id) }
    }

    private var quickLookFiles: [URL] {
        SelectionSummary(rows: selectedRows).finishedFiles
    }

    private var panels: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                LibrarySidebar(view: view, selection: $selectionInSidebar, freeSpace: model.freeSpace)
                    .frame(width: Self.sidebarWidth)
                    .transition(.move(edge: .leading))
                Divider()
            }
            detail
                .frame(minWidth: Self.listMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                .sheet(isPresented: showsWelcome) {
                    OnboardingSheet(model: model) { hasSeenWelcome = true }
                        .interactiveDismissDisabled()
                }
            if showsInspector {
                Divider()
                inspector
                    .frame(width: Self.inspectorWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .background(LibraryWindowAccessor(model: model))
        .windowGlass()
        .frame(minWidth: minimumWidth, minHeight: 420)
        .navigationTitle(selectionInSidebar.title)
        .navigationSubtitle(view.summary)
        .searchable(text: $search, placement: .toolbar, prompt: "Search downloads")
        .modifier(SearchFocus(isFocused: $isSearching))
        .toolbar { toolbar }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    var body: some View {
        panels
            .focusedSceneValue(\.panelToggles, PanelToggles(
                sidebarShown: showsSidebar, inspectorShown: showsInspector,
                toggleSidebar: { togglePanel($showsSidebar) }, toggleInspector: { togglePanel($showsInspector) }
            ))
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear {
                isFocused = true
                model.isLibraryWindowOpen = true
                model.openLibraryWindow = { [openWindow] in openWindow(id: LibraryWindow.sceneID) }
                model.openSettingsWindow = { [openSettings] in openSettings() }
            }
            .onDisappear { model.isLibraryWindowOpen = false }
            .task {
                guard DebugLaunch.isOn else { return }
                try? await Task.sleep(for: .seconds(1))
                DebugLaunch.applyWindowWidth()
                if DebugLaunch.showsInspector, !showsInspector { togglePanel($showsInspector) }
                if DebugLaunch.opensSettings { model.showSettings() }
                if DebugLaunch.togglesSidebar {
                    try? await Task.sleep(for: .seconds(1))
                    togglePanel($showsSidebar)
                }
            }
            .modifier(SelectionKeys(selection: $selection, rows: rowIDs) {
                guard let file = quickLookFiles.first else { return false }
                quickLookFile = quickLookFile == nil ? file : nil
                return true
            })
            .onPasteCommand(of: [.url, .plainText]) { _ in
                let pasteboard = NSPasteboard.general
                model.requestNewDownload(pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) ?? "")
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.requestNewDownload(urls.map(\.absoluteString).joined(separator: "\n"))
                return true
            }
            .sheet(item: newDownloadSheet) { sheet in
                NewDownloadSheet(sheet: sheet) { model.add($0) }
            }
            .focusedSceneValue(\.findInLibrary, SearchFocus.isAvailable ? FindInLibrary { isSearching = true } : nil)
            .focusedSceneValue(\.selectedDownloads, SelectedDownloads(
                rows: selectedRows, actions: actions, quickLook: { quickLookFile = quickLookFiles.first }
            ))
            .quickLookPreview($quickLookFile, in: quickLookFiles)
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
        ToolbarItem(placement: .navigation) {
            Button("Sidebar", systemImage: "sidebar.left") { togglePanel($showsSidebar) }
                .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
        }
        ToolbarItemGroup {
            Button("Clear Completed", systemImage: "checkmark.circle") { model.clearCompleted() }
                .help("Clear Completed")
                .disabled(!view.canClearCompleted)
            Button("Resume", systemImage: "play.fill") {
                if selectedRows.isEmpty { model.resumeAll() } else { actions.resume(selectedRows) }
            }
            .help(selectedRows.isEmpty ? "Resume All" : "Resume Selected")
            .disabled(selectedRows.isEmpty ? !view.canResumeAll : SelectionSummary(rows: selectedRows).resumable.isEmpty)
            Button("Pause", systemImage: "pause.fill") {
                if selectedRows.isEmpty { model.pauseAll() } else { actions.pause(selectedRows) }
            }
            .help(selectedRows.isEmpty ? "Pause All" : "Pause Selected")
            .disabled(selectedRows.isEmpty ? !view.canPauseAll : SelectionSummary(rows: selectedRows).pausable.isEmpty)
            Button("New Download", systemImage: "plus") { model.requestNewDownload() }
                .help("New Download")
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") { togglePanel($showsInspector) }
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
                ContentUnavailableView(selectionInSidebar.emptyText, systemImage: selectionInSidebar.symbolName)
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            DownloadList(
                rows: view.rows, selection: $selection, actions: actions,
                quickLook: { quickLookFile = quickLookFiles.first },
                open: { openWindow(id: DetailWindow.sceneID, value: $0.id) },
                focusList: { isFocused = true }
            )
        }
    }

    /// The toolbar spans the whole window and never changes with the panels, so this one width
    /// keeps every button out of the overflow menu.
    private static let toolbarMinimumWidth: CGFloat = 700
    private static let listMinimumWidth: CGFloat = 360
    private static let sidebarWidth: CGFloat = 230
    private static let inspectorWidth: CGFloat = 280

    /// Opening a panel in a narrow window widens the window instead of squeezing the list.
    private var minimumWidth: CGFloat {
        let panels = (showsSidebar ? Self.sidebarWidth : 0) + (showsInspector ? Self.inspectorWidth : 0)
        return max(Self.toolbarMinimumWidth, Self.listMinimumWidth + panels)
    }

    private var rowIDs: [DownloadID] { view.rows.map(\.id) }

    @ViewBuilder private var inspector: some View {
        let rows = selectedRows
        if rows.count > 1 {
            SelectionInspector(rows: rows, actions: actions)
        } else {
            InspectorView(row: rows.first, actions: actions)
        }
    }

    private func togglePanel(_ isShown: Binding<Bool>) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { isShown.wrappedValue.toggle() }
    }

    /// A window shows one sheet at a time, so the New Download sheet waits for onboarding to
    /// close, and Show Welcome Again waits for the New Download sheet.
    private var showsWelcome: Binding<Bool> {
        Binding(get: { !hasSeenWelcome && model.newDownload == nil }, set: { if !$0 { hasSeenWelcome = true } })
    }

    private var newDownloadSheet: Binding<NewDownloadModel?> {
        Binding(get: { hasSeenWelcome ? model.newDownload : nil }, set: { model.newDownload = $0 })
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })
    }
}

/// The keys that change the selection as in Finder, and Space for Quick Look.
private struct SelectionKeys: ViewModifier {
    @Binding var selection: RowSelection
    let rows: [DownloadID]
    let toggleQuickLook: () -> Bool

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.downArrow, .upArrow]) { press in
                guard !rows.isEmpty else { return .ignored }
                selection.move(by: press.key == .downArrow ? 1 : -1, in: rows, extending: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.selected.isEmpty else { return .ignored }
                selection.clear()
                return .handled
            }
            .onKeyPress(.space) { toggleQuickLook() ? .handled : .ignored }
            .onCommand(#selector(NSResponder.selectAll(_:))) { selection.selectAll(in: rows) }
            .onChange(of: rows) { _, ids in selection.keepOnly(ids) }
    }
}

/// Not a sidebar `List`: macOS treats one specially next to the title bar, which made the toolbar
/// redraw while the sidebar slid away.
private struct LibrarySidebar: View {
    let view: LibraryView
    @Binding var selection: LibrarySelection
    let freeSpace: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading("Library")
                ForEach(LibraryFilter.allCases, id: \.self) { filter in
                    item(.filter(filter), count: view.counts[filter] ?? 0)
                }
                heading("Categories").padding(.top, DowlioDesign.Spacing.sm)
                ForEach(FileCategory.allCases, id: \.self) { category in
                    item(.category(category), count: view.categoryCounts[category] ?? 0)
                }
            }
            .padding(DowlioDesign.Spacing.sm)
        }
        .scrollIndicators(.never)
        .modifier(NoScrollEdgeEffect())
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

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(DowlioDesign.TypeRole.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.bottom, DowlioDesign.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func item(_ choice: LibrarySelection, count: Int) -> some View {
        let isSelected = selection == choice
        return Button { selection = choice } label: {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                Image(systemName: choice.symbolName)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: DowlioDesign.Spacing.xl)
                Text(choice.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(DowlioDesign.TypeRole.body)
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.vertical, DowlioDesign.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionBackground(isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(choice.title), \(count)" : choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Newer macOS draws a band behind the toolbar wherever a scroll view meets it. The toolbar
/// stays the same in every layout, so the band is off everywhere.
struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

extension LibrarySelection {
    var symbolName: String {
        switch self {
        case .filter(let filter): filter.symbolName
        case .category(let category): category.symbolName
        }
    }

    var emptyText: String {
        switch self {
        case .filter(let filter): filter.emptyText
        case .category(let category): "Nothing in \(category.folderName) yet"
        }
    }
}

extension FileCategory {
    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .appsAndDiskImages: "shippingbox"
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

/// SwiftUI can move focus to the search field only from macOS 15, so ⌘F is off before that.
private struct SearchFocus: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    static var isAvailable: Bool {
        if #available(macOS 15, *) { true } else { false }
    }

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

struct PanelToggles {
    let sidebarShown: Bool
    let inspectorShown: Bool
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
}

extension FocusedValues {
    @Entry var panelToggles: PanelToggles?
}

struct PanelCommands: Commands {
    @FocusedValue(\.panelToggles) private var panels

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(panels?.sidebarShown == false ? "Show Sidebar" : "Hide Sidebar") { panels?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(panels == nil)
            Button(panels?.inspectorShown == true ? "Hide Inspector" : "Show Inspector") { panels?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.control, .command])
                .disabled(panels == nil)
        }
    }
}
