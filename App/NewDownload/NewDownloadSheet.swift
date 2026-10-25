import DowlioCore
import DowlioLibrary
import SwiftUI
import UniformTypeIdentifiers

struct NewDownloadSheet: View {
    @Bindable var sheet: NewDownloadModel
    let onDownload: (NewDownloadDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            Text("New Download").font(DowlioDesign.TypeRole.title)
            linkField
            if !sheet.draft.lines.isEmpty { cards }
            if let explanation = sheet.draft.explanation {
                Text(explanation).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.md) {
                GridRow {
                    Text("Save to")
                    HStack {
                        Label(sheet.draft.folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sheet.draft.folder.path(percentEncoded: false))
                        Spacer()
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                GridRow {
                    Text("Connections")
                    HStack {
                        Stepper(value: $sheet.draft.connections, in: 1...16) {
                            Text("\(sheet.draft.connections)").monospacedDigit()
                        }
                        Text("8 to 16 is fastest").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Advanced") {
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
                Toggle("Start immediately", isOn: $sheet.draft.startImmediately)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.draft.downloadsAnyway ? "Download Anyway" : "Download") {
                    onDownload(sheet.draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.draft.canDownload)
            }
        }
        .padding(DowlioDesign.Spacing.xl)
        .frame(width: 520)
        .task { sheet.checkLinks() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { sheet.draft.folder = folder }
        }
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

    @ViewBuilder private var cards: some View {
        let list = VStack(spacing: DowlioDesign.Spacing.sm) {
            ForEach(Array(sheet.draft.lines.enumerated()), id: \.offset) { _, line in
                FileCard(line: line, sheet: sheet)
            }
        }
        if sheet.draft.lines.count > 3 {
            ScrollView { list }.frame(height: 260)
        } else {
            list
        }
    }
}

private struct FileCard: View {
    let line: PastedLinks.Line
    @Bindable var sheet: NewDownloadModel

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
        if sheet.draft.isSingleLink, line.problem == nil {
            TextField("File name", text: Binding(get: { sheet.draft.fileName }, set: { sheet.draft.rename($0) }))
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
