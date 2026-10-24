import AppKit
import DowlioLibrary
import SwiftUI

/// The library window: every download, newest first. ⌘V adds a pasted link.
struct LibraryWindow: View {
    let model: AppModel

    var body: some View {
        Group {
            if let problem = model.problem {
                ContentUnavailableView("Dowlio can't start", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    "No downloads yet", systemImage: "tray",
                    description: Text("Paste a link with ⌘V.")
                )
            } else {
                List(model.rows) { row in
                    DownloadRowView(row: row, model: model)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .focusable()
        .focusEffectDisabled()
        .onPasteCommand(of: [.url, .plainText]) { _ in
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
                model.add(pasted: text)
            }
        }
    }
}
