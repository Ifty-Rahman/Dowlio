import AppKit
import DowlioLibrary
import SwiftUI

struct FrontPageBody: View {
    let sheet: NewDownloadModel
    let state: FrontPageState
    @State private var clipboardHasNoLink = false

    var body: some View {
        switch state {
        case .asking:
            HStack(spacing: DowlioDesign.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(state.line ?? "")
            }
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DowlioDesign.Spacing.sm)
        case .couldntRead(let reason):
            VStack(spacing: DowlioDesign.Spacing.sm) {
                Image(systemName: "questionmark.text.page")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(CouldntRead.title).font(DowlioDesign.TypeRole.heading)
                Text(reason.explanation)
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use the link on the clipboard") {
                        clipboardHasNoLink = !sheet.useClipboard(NSPasteboard.general.string(forType: .string))
                    }
                    if reason.opensAutomationSettings {
                        Button("Open Automation Settings") { FrontBrowser.openAutomationSettings() }
                    }
                }
                if clipboardHasNoLink {
                    Text("There's no link on the clipboard.")
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DowlioDesign.Spacing.sm)
            .onChange(of: state) { clipboardHasNoLink = false }
        }
    }
}
