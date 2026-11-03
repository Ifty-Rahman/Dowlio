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
        .padding(DowlioDesign.Spacing.lg)
        .frame(width: 340, alignment: .leading)
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
            .onSubmit { if sheet.canDownload { download(sheet) } }
        let items = sheet.list.items
        if let state = sheet.frontPage {
            FrontPageBody(sheet: sheet, state: state)
                .padding(.horizontal, DowlioDesign.Spacing.md)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        }
        if items.count > 1 {
            LinkPager(sheet: sheet, makesDefaultQuality: Bindable(sheet).makesDefaultQuality)
                .padding(DowlioDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            Text(sheet.list.includedLine)
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
        } else if let item = items.first {
            singleItem(item, of: sheet)
                .showsInList(item, of: sheet.list)
            if item.savesAFile {
                TextField("File name", text: Binding(get: { sheet.fileName(of: item) }, set: { sheet.rename(item, to: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("File name")
            }
        } else if let explanation = sheet.draft.explanation {
            Text(explanation).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
        }
        HStack {
            Button("Open Dowlio") {
                panel.showsQuickAdd = false
                panel.quickAdd = nil
                close()
                model.continueInWindow(sheet)
            }
            .keyboardShortcut(.return, modifiers: .command)
            Spacer()
            Button("Cancel", role: .cancel) {
                panel.endQuickAdd()
                close()
            }
            .keyboardShortcut(.cancelAction)
            Button(sheet.downloadTitle) { download(sheet) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.canDownload)
        }
    }

    @ViewBuilder private func singleItem(_ item: LinkItem, of sheet: NewDownloadModel) -> some View {
        switch item.kind {
        case .checking(let url), .file(let url, _):
            LinkCard(url: url, check: sheet.draft.check(for: url))
        case .page(let page) where page.draft.phase == .needsSignIn:
            NeedsSignInBody(media: page)
                .padding(.horizontal, DowlioDesign.Spacing.md)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        case .page(let page) where page.draft.phase == .blocked:
            BlockedBody(media: page)
                .padding(.horizontal, DowlioDesign.Spacing.md)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        case .page(let page) where page.draft.phase == .nothingFound:
            NothingFoundBody(media: page)
                .padding(.horizontal, DowlioDesign.Spacing.md)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
        case .page(let page), .video(let page, _):
            MediaCard(media: page, makesDefaultQuality: Bindable(sheet).makesDefaultQuality)
        }
    }

    private func download(_ sheet: NewDownloadModel) {
        model.addList(sheet)
        panel.showsQuickAdd = false
        panel.quickAdd = nil
        close()
    }
}

private struct MediaCard: View {
    let media: SentPageModel
    @Binding var makesDefaultQuality: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            switch media.draft.phase {
            case .looking, .playing:
                HStack(spacing: DowlioDesign.Spacing.md) {
                    InitialTile(host: media.draft.host).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        Text(media.draft.page.title ?? media.draft.host).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                        LookingLine(media: media)
                    }
                }
            default:
                MediaHeader(media: media)
                MediaChoices(media: media, makesDefaultQuality: $makesDefaultQuality)
            }
        }
        .padding(DowlioDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
    }
}
