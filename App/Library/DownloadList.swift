import DowlioCore
import DowlioLibrary
import SwiftUI

/// The library's rows in a plain scrolling stack. `List` sits on a table that keeps each row's
/// first measured height, so rows added while the list was busy could stay squashed. Here every
/// row is measured each time it's drawn.
struct DownloadList: View {
    let rows: [DownloadRow]
    @Binding var selection: DownloadID?
    let actions: RowActions
    let quickLook: (DownloadRow) -> Void
    let open: (DownloadRow) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, DowlioDesign.Spacing.md + 44 + DowlioDesign.Spacing.md)
                        }
                        line(row)
                    }
                }
                .padding(DowlioDesign.Spacing.sm)
            }
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
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested)
                        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = row.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
            .contextMenu {
                RowMenuItems(row: row, actions: actions, quickLook: quickLook)
                    .onAppear { selection = row.id }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .id(row.id)
    }
}
