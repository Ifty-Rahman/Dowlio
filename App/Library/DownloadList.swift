import AppKit
import DowlioCore
import DowlioLibrary
import SwiftUI

/// Not a `List`: its table keeps each row's first measured height, so rows added while it was
/// busy could stay squashed. Selection works as in Finder: click, ⌘-click, ⇧-click, and dragging a
/// rectangle across rows. Rows scrolled out of view keep their last known place, so a drag that
/// scrolls still covers them.
struct DownloadList: View {
    let rows: [DownloadRow]
    @Binding var selection: RowSelection
    let actions: RowActions
    let quickLook: () -> Void
    let open: (DownloadRow) -> Void
    /// Clicking a row takes focus back from the search field, so ↑, ↓ and Space reach the list.
    let focusList: () -> Void

    @State private var rowFrames: [DownloadID: CGRect] = [:]
    @State private var dragRect: CGRect?
    @State private var selectionBeforeDrag: Set<DownloadID> = []

    private static let space = "downloadList"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                                .padding(.leading, DowlioDesign.Spacing.xxl + DowlioDesign.Spacing.xxl + DowlioDesign.Spacing.xxl)
                                .opacity(touchesSelection(rows[index - 1], row) ? 0 : 1)
                        }
                        line(row)
                    }
                }
                .padding(DowlioDesign.Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.clear()
                    focusList()
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(RowFrames.self) { rowFrames.merge($0) { $1 } }
                .overlay(alignment: .topLeading) { dragOverlay }
                .simultaneousGesture(dragToSelect)
            }
            .modifier(NoScrollEdgeEffect())
            .onChange(of: ids) { _, ids in rowFrames = rowFrames.filter { ids.contains($0.key) } }
            .onChange(of: selection.selected) { _, selected in
                if selected.count == 1, let id = selected.first { proxy.scrollTo(id) }
            }
        }
    }

    private func line(_ row: DownloadRow) -> some View {
        let isSelected = selection.contains(row.id)
        return DownloadRowView(row: row, actions: actions)
            .padding(.horizontal, DowlioDesign.Spacing.md)
            .padding(.vertical, DowlioDesign.Spacing.xs)
            .selectionBackground(isSelected)
            .contentShape(Rectangle())
            .background(GeometryReader { proxy in
                Color.clear.preference(key: RowFrames.self, value: [row.id: proxy.frame(in: .named(Self.space))])
            })
            .onTapGesture {
                selection.click(row.id, in: ids, modifiers: Self.currentModifiers)
                focusList()
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
            .contextMenu {
                SelectionMenuItems(rows: menuRows(for: row), actions: actions, quickLook: quickLook)
                    .onAppear { selection.prepareContextMenu(for: row.id, in: ids) }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { selection.click(row.id, in: ids) }
            .accessibilityAction(named: "Add to Selection") { selection.click(row.id, in: ids, modifiers: .command) }
            .accessibilityAction(named: "Show Details") { open(row) }
            .id(row.id)
    }

    private var ids: [DownloadID] { rows.map(\.id) }

    /// A line next to a selected row would cut into its highlight, so it gives way and only its space stays.
    private func touchesSelection(_ above: DownloadRow, _ below: DownloadRow) -> Bool {
        selection.contains(above.id) || selection.contains(below.id)
    }

    /// A right-click on a selected row acts on the whole selection, and on that row alone otherwise.
    private func menuRows(for row: DownloadRow) -> [DownloadRow] {
        selection.contains(row.id) ? rows.filter { selection.contains($0.id) } : [row]
    }

    private var dragToSelect: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { drag in
                if dragRect == nil { selectionBeforeDrag = selection.selected }
                let rect = CGRect(
                    x: min(drag.startLocation.x, drag.location.x), y: min(drag.startLocation.y, drag.location.y),
                    width: abs(drag.location.x - drag.startLocation.x), height: abs(drag.location.y - drag.startLocation.y)
                )
                dragRect = rect
                let touched = ids.filter { rowFrames[$0]?.intersects(rect) == true }
                selection.drag(over: touched, adding: Self.currentModifiers.contains(.command), base: selectionBeforeDrag)
            }
            .onEnded { _ in
                dragRect = nil
                focusList()
            }
    }

    @ViewBuilder private var dragOverlay: some View {
        if let dragRect {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                .frame(width: dragRect.width, height: dragRect.height)
                .offset(x: dragRect.minX, y: dragRect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static var currentModifiers: RowSelection.Modifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: RowSelection.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

private struct RowFrames: PreferenceKey {
    static let defaultValue: [DownloadID: CGRect] = [:]

    static func reduce(value: inout [DownloadID: CGRect], nextValue: () -> [DownloadID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
