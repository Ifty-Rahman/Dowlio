import DowlioCore
import DowlioLibrary
import SwiftUI

/// Not a `List`: its table keeps each row's first measured height, so rows added while it was
/// busy could stay squashed.
struct DownloadList: View {
    let rows: [DownloadRow]
    @Binding var selection: DownloadID?
    let actions: RowActions
    let quickLook: (DownloadRow) -> Void
    let open: (DownloadRow) -> Void
    /// Clicking a row takes focus back from the search field, so ↑, ↓ and Space reach the list.
    let focusList: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, DowlioDesign.Spacing.xxl + DowlioDesign.Spacing.xxl + DowlioDesign.Spacing.xxl)
                        }
                        line(row)
                    }
                }
                .padding(DowlioDesign.Spacing.sm)
            }
            .modifier(NoScrollEdgeEffect())
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func line(_ row: DownloadRow) -> some View {
        let isSelected = selection == row.id
        return DownloadRowView(row: row, actions: actions)
            .padding(.horizontal, DowlioDesign.Spacing.md)
            .padding(.vertical, DowlioDesign.Spacing.xs)
            .selectionBackground(isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                selection = row.id
                focusList()
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
            .contextMenu {
                RowMenuItems(row: row, actions: actions, quickLook: quickLook)
                    .onAppear { selection = row.id }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { selection = row.id }
            .accessibilityAction(named: "Show Details") { open(row) }
            .id(row.id)
    }
}
