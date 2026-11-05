import DowlioLibrary
import SwiftUI

struct ToolsBody: View {
    let media: SentPageModel
    @State private var keepsUpToDate = true

    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            switch media.draft.phase {
            case .installingTools:
                ProgressView().controlSize(.small)
                line(media.draft.installingLine)
            case .declinedTools:
                icon("shippingbox")
                line(media.draft.declinedLine)
                Button("Download yt-dlp…") { media.askForToolsAgain() }
            case .couldntInstallTools:
                icon("exclamationmark.triangle")
                line(media.draft.couldntInstallLine)
                Button("Try Again") { media.askForToolsAgain() }
            case .toolsChanged:
                icon("exclamationmark.shield")
                line(media.draft.toolsChangedLine)
                Button("Reinstall") { media.reinstallTools() }
            default:
                consent(media.draft.toolConsent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DowlioDesign.Spacing.sm)
    }

    private func consent(_ text: ToolConsentText) -> some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            icon("shippingbox")
            Text(text.title).font(DowlioDesign.TypeRole.heading)
            line(text.explanation)
            HStack(spacing: DowlioDesign.Spacing.md) {
                ForEach(text.tools, id: \.name) { tool in
                    Link(destination: tool.project) {
                        Label {
                            Text(tool.name)
                        } icon: {
                            Image("GitHubMark").resizable().frame(width: 12, height: 12)
                        }
                    }
                    .help(tool.project.absoluteString)
                }
            }
            .font(DowlioDesign.TypeRole.detail)
            Toggle("Keep yt-dlp up to date", isOn: $keepsUpToDate)
                .toggleStyle(.checkbox)
                .font(DowlioDesign.TypeRole.detail)
            HStack {
                Button(text.decline) { media.declineTools() }
                Button(text.agree) { media.agreeToTools(keepUpToDate: keepsUpToDate) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { keepsUpToDate = text.keepsUpToDate }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 26))
            .foregroundStyle(.secondary)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
