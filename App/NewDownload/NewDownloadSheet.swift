import DowlioCore
import DowlioLibrary
import SwiftUI
import UniformTypeIdentifiers

struct NewDownloadSheet: View {
    let model: AppModel
    @Bindable var sheet: NewDownloadModel
    let close: () -> Void
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Download").font(DowlioDesign.TypeRole.title)
                Spacer()
                if let sentFrom {
                    Text(sentFrom).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                }
            }
            linkField
            if let state = sheet.frontPage {
                FrontPageBody(sheet: sheet, state: state)
            }
            let items = sheet.list.items
            if items.count > 1 {
                LinkPager(sheet: sheet, makesDefaultQuality: $sheet.makesDefaultQuality, boxed: true)
                Text(sheet.list.includedLine).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            } else if let item = items.first {
                singleItem(item)
                    .showsInList(item, of: sheet.list)
            }
            skippedLines
            if let explanation = sheet.draft.explanation {
                Text(explanation).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: DowlioDesign.Spacing.lg) {
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text("Save to").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    HStack {
                        Label(sheet.draft.folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sheet.draft.folder.path(percentEncoded: false))
                        Spacer()
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text("Connections").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    HStack {
                        Stepper(value: $sheet.draft.connections, in: 1...16) {
                            Text("\(sheet.draft.connections)").monospacedDigit()
                        }
                        Text("8 to 16 is fastest").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Start immediately", isOn: $sheet.draft.startImmediately)
                .toggleStyle(.switch)
                .controlSize(.small)
            DisclosureGroup("Advanced: referrer and user agent") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.sm) {
                    GridRow {
                        Text("Referrer")
                        TextField("https://example.com/page", text: $sheet.draft.referrer).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("User agent")
                        TextField("Your Mac's default", text: $sheet.draft.userAgent).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, DowlioDesign.Spacing.sm)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(sheet.downloadTitle, action: download)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sheet.canDownload)
            }
        }
        .padding(DowlioDesign.Spacing.xl)
        .frame(width: 560)
        .task { sheet.checkLinks() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { sheet.draft.folder = folder }
        }
    }

    @ViewBuilder private func singleItem(_ item: LinkItem) -> some View {
        switch item.kind {
        case .checking(let url), .file(let url, _):
            FileCard(line: .link(url), sheet: sheet, item: item)
        case .page(let page), .video(let page, _):
            mediaBlock(page, item: item)
        }
    }

    @ViewBuilder private func mediaBlock(_ media: SentPageModel, item: LinkItem) -> some View {
        switch media.draft.phase {
        case .looking, .playing:
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
                MediaHeader(media: media)
                SkeletonRows()
                LookingLine(media: media)
            }
        case .found, .restricted:
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
                MediaHeader(media: media, subtitle: versionsLine(media))
                MediaChoices(media: media, makesDefaultQuality: $sheet.makesDefaultQuality, boxed: true)
                if item.savesAFile {
                    VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        Text("File name").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                        TextField("File name", text: Binding(get: { sheet.fileName(of: item) }, set: { sheet.rename(item, to: $0) }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        case .nothingFound:
            MediaHeader(media: media)
            NothingFoundBody(media: media)
            if item.savesAFile {
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text("File name").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    TextField("File name", text: Binding(get: { sheet.fileName(of: item) }, set: { sheet.rename(item, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .needsSignIn:
            MediaHeader(media: media)
            NeedsSignInBody(media: media)
        case .blocked:
            MediaHeader(media: media)
            BlockedBody(media: media)
        case .ytdlpFailed:
            MediaHeader(media: media)
            ProblemBody(media: media)
        case .playlist:
            PlaylistBody(media: media)
        default:
            MediaHeader(media: media)
            ToolsBody(media: media)
        }
    }

    private func versionsLine(_ media: SentPageModel) -> String {
        let count = media.draft.selectedCandidate?.versions.count ?? 0
        return "\(media.draft.host) · \(count) \(count == 1 ? "version" : "versions")"
    }

    private var sentFrom: String? {
        guard let url = sheet.draft.links.first, let origin = sheet.draft.origin(for: url), origin.kind == .sent else { return nil }
        let signedIn = !sheet.draft.options(for: url).cookies.isEmpty
        return "Sent from \(origin.browser ?? "your browser")" + (signedIn ? ", signed in" : "")
    }

    private func download() {
        model.addList(sheet)
        close()
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
            Text("Link")
            TextEditor(text: $sheet.draft.text)
                .font(DowlioDesign.TypeRole.body)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(DowlioDesign.Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
                .overlay(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Link")
            Text("Paste several links, one per line, to add them all at once.")
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var skippedLines: some View {
        ForEach(Array(sheet.draft.lines.enumerated()), id: \.offset) { _, line in
            if line.problem != nil { FileCard(line: line, sheet: sheet, item: nil) }
        }
    }
}

private struct FileCard: View {
    let line: PastedLinks.Line
    @Bindable var sheet: NewDownloadModel
    let item: LinkItem?

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            FileTypeBadge(text: (title as NSString).pathExtension.uppercased())
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                name
                if let problem = line.problem {
                    Text(problem).font(DowlioDesign.TypeRole.detail).foregroundStyle(LinkStatus.Tone.problem.color)
                } else if let status = check?.status {
                    HStack(alignment: .firstTextBaseline, spacing: DowlioDesign.Spacing.sm) {
                        if status.tone == .neutral { ProgressView().controlSize(.small) }
                        LinkStatusLine(status: status, size: inspection?.totalBytes)
                        if inspection?.isNotSecure ?? (line.url?.scheme?.lowercased() == "http") {
                            Label("Not secure", systemImage: "lock.open.fill")
                                .foregroundStyle(LinkStatus.Tone.caution.color)
                                .fixedSize()
                        }
                    }
                    .font(DowlioDesign.TypeRole.detail)
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
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var name: some View {
        if let item, line.problem == nil {
            TextField("File name", text: Binding(get: { sheet.fileName(of: item) }, set: { sheet.rename(item, to: $0) }))
                .textFieldStyle(.plain)
                .font(DowlioDesign.TypeRole.heading)
        } else {
            Text(title).font(DowlioDesign.TypeRole.heading).lineLimit(1).truncationMode(.middle)
        }
    }

    private var check: NewDownloadDraft.Check? { line.url.flatMap(sheet.draft.check(for:)) }

    private var inspection: LinkInspection? {
        if case .inspected(let inspection) = check { inspection } else { nil }
    }

    private var title: String {
        if let inspection { return inspection.fileName }
        switch line {
        case .link(let url): return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case .notALink(let text): return text
        case .unsupported(let url): return url.absoluteString
        }
    }
}

struct LinkStatusLine: View {
    let status: LinkStatus
    let size: Int64?

    var body: some View {
        var line = Text(status.line).foregroundStyle(status.tone.color)
        if let size {
            line = line + Text(" · \(ByteText.string(size))").foregroundStyle(.secondary).monospacedDigit()
        }
        return line.fixedSize(horizontal: false, vertical: true)
    }
}

extension LinkStatus.Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: DownloadRow.State.completed.tone
        case .caution: DownloadRow.State.retrying(attempt: 0, nextTry: .distantPast).tone
        case .problem: DownloadRow.State.failed(.notFound).tone
        }
    }
}
