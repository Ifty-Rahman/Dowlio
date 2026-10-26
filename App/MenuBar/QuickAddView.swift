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
        let links = sheet.draft.links
        if let media = sheet.media, media.draft.phase != .nothingFound {
            MediaCard(media: media, showing: Bindable(sheet).showing)
        } else {
            if let media = sheet.media, media.draft.phase == .nothingFound {
                Label("No video or audio on this page", systemImage: "video.slash")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
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
        }
        HStack {
            Button("Open Dowlio") {
                panel.showsQuickAdd = false
                panel.quickAdd = nil
                close()
                model.continueInWindow(sheet)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                panel.endQuickAdd()
                close()
            }
            .keyboardShortcut(.cancelAction)
            Button(downloadTitle(sheet)) { download(sheet) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.canDownload)
        }
    }

    private func downloadTitle(_ sheet: NewDownloadModel) -> String {
        if let media = sheet.media, media.draft.phase == .found {
            let count = media.draft.downloads.count
            return count > 1 ? "Download \(count)" : "Download"
        }
        if sheet.draft.downloadsAnyway { return "Download Anyway" }
        return sheet.draft.links.count > 1 ? "Download All" : "Download"
    }

    private func download(_ sheet: NewDownloadModel) {
        if let media = sheet.media, media.draft.phase == .found {
            let draft = sheet.draft
            let fileName = sheet.chosenFileName
            Task { await model.addMedia(draft, media: media, fileName: fileName) }
        } else {
            model.add(sheet.draft)
        }
        panel.showsQuickAdd = false
        panel.quickAdd = nil
    }
}

private struct MediaCard: View {
    let media: SentPageModel
    @Binding var showing: SentPageDraft.Showing

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            switch media.draft.phase {
            case .looking:
                HStack(spacing: DowlioDesign.Spacing.md) {
                    InitialTile(host: media.draft.host).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        Text(media.draft.page.title ?? media.draft.host).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                        HStack(spacing: DowlioDesign.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Looking for video and audio…")
                        }
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(.secondary)
                    }
                }
            default:
                MediaHeader(media: media)
                if media.draft.candidates.count > 1 { VideoStrip(media: media) }
                if media.draft.hasVideoAndAudio {
                    Picker("Show", selection: $showing) {
                        Text("Video").tag(SentPageDraft.Showing.video)
                        Text("Audio").tag(SentPageDraft.Showing.audio)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                VersionRows(media: media, showing: showing)
            }
        }
        .padding(DowlioDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
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
