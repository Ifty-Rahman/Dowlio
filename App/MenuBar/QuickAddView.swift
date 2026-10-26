import DowlioCore
import DowlioLibrary
import SwiftUI

struct QuickAddView: View {
    let model: AppModel
    let panel: MenuBarPanel
    let close: () -> Void
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            Text("Add Link").font(DowlioDesign.TypeRole.title).accessibilityAddTraits(.isHeader)
            if let sheet = panel.quickAdd {
                content(sheet)
            }
        }
        .onAppear {
            if panel.quickAdd == nil { panel.quickAdd = model.makeNewDownload(DebugLaunch.quickAddLink ?? "") }
            panel.quickAdd?.checkLinks()
            linkFocused = true
        }
    }

    @ViewBuilder private func content(_ sheet: NewDownloadModel) -> some View {
        TextField("https://…", text: Bindable(sheet).draft.text)
            .textFieldStyle(.roundedBorder)
            .focused($linkFocused)
            .onSubmit { if sheet.draft.canDownload { download(sheet) } }
        let links = sheet.draft.links
        if links.count == 1, let url = links.first {
            QuickAddCard(url: url, check: sheet.draft.check(for: url))
        } else if links.count > 1 {
            Label("\(links.count) links", systemImage: "link")
                .font(DowlioDesign.TypeRole.heading)
                .padding(DowlioDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        } else if let explanation = sheet.draft.explanation {
            Text(explanation).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
        }
        HStack {
            Button("Open Dowlio") {
                panel.quickAdd = nil
                close()
                model.continueInWindow(sheet)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                panel.quickAdd = nil
                close()
            }
                .keyboardShortcut(.cancelAction)
            Button(downloadTitle(sheet)) { download(sheet) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.draft.canDownload)
        }
    }

    private func downloadTitle(_ sheet: NewDownloadModel) -> String {
        if sheet.draft.downloadsAnyway { return "Download Anyway" }
        return sheet.draft.links.count > 1 ? "Download All" : "Download"
    }

    private func download(_ sheet: NewDownloadModel) {
        model.add(sheet.draft)
        panel.quickAdd = nil
        close()
    }
}

private struct QuickAddCard: View {
    let url: URL
    let check: NewDownloadDraft.Check?

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            FileTypeBadge(text: (name as NSString).pathExtension.uppercased())
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                Text(name).font(DowlioDesign.TypeRole.heading).lineLimit(1).truncationMode(.middle)
                if let status = check?.status {
                    HStack(spacing: DowlioDesign.Spacing.xs) {
                        if status.tone == .neutral { ProgressView().controlSize(.small) }
                        LinkStatusLine(status: status, size: inspection?.totalBytes)
                    }
                    .font(DowlioDesign.TypeRole.detail)
                    if inspection?.isNotSecure ?? (url.scheme?.lowercased() == "http") {
                        Label("Not secure", systemImage: "lock.open.fill")
                            .font(DowlioDesign.TypeRole.detail)
                            .foregroundStyle(LinkStatus.Tone.caution.color)
                    }
                    if let reason = status.reason {
                        Text(reason)
                            .font(DowlioDesign.TypeRole.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DowlioDesign.Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        .accessibilityElement(children: .combine)
    }

    private var inspection: LinkInspection? {
        if case .inspected(let inspection) = check { inspection } else { nil }
    }

    private var name: String {
        inspection?.fileName ?? (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
    }
}
