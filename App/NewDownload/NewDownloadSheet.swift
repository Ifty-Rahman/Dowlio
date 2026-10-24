import DowlioCore
import DowlioLibrary
import SwiftUI
import UniformTypeIdentifiers

struct NewDownloadSheet: View {
    @State private var sheet: NewDownloadModel
    let shown: (NewDownloadModel) -> Void
    let add: (NewDownloadModel) -> Void

    init(
        sheet: @autoclosure @escaping () -> NewDownloadModel,
        shown: @escaping (NewDownloadModel) -> Void,
        add: @escaping (NewDownloadModel) -> Void
    ) {
        _sheet = State(wrappedValue: sheet())
        self.shown = shown
        self.add = add
    }
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            Text("New Download").font(DowlioDesign.TypeRole.title)
            linkField
            if !sheet.lines.isEmpty { cards }
            if let explanation = sheet.explanation {
                Text(explanation).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.md) {
                GridRow {
                    Text("Save to")
                    HStack {
                        Label(sheet.folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sheet.folder.path(percentEncoded: false))
                        Spacer()
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                GridRow {
                    Text("Connections")
                    HStack {
                        Stepper(value: Bindable(sheet).connections, in: 1...16) {
                            Text("\(sheet.connections)").monospacedDigit()
                        }
                        Text("8 to 16 is fastest").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Advanced") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.sm) {
                    GridRow {
                        Text("Referrer")
                        TextField("https://example.com/page", text: Bindable(sheet).referrer).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("User agent")
                        TextField("Your Mac's default", text: Bindable(sheet).userAgent).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, DowlioDesign.Spacing.sm)
            }
            HStack {
                Toggle("Start immediately", isOn: Bindable(sheet).startImmediately).toggleStyle(.switch)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.downloadsAnyway ? "Download Anyway" : "Download") {
                    add(sheet)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!sheet.canDownload)
            }
        }
        .padding(DowlioDesign.Spacing.xl)
        .frame(width: 520)
        .onAppear { shown(sheet) }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { sheet.folder = folder }
        }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
            Text("Link")
            TextEditor(text: Bindable(sheet).text)
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
            ForEach(Array(sheet.lines.enumerated()), id: \.offset) { _, line in
                FileCard(line: line, sheet: sheet)
            }
        }
        if sheet.lines.count > 3 {
            ScrollView { list }.frame(height: 260)
        } else {
            list
        }
    }
}

/// One pasted line: the file a link gives, or why the line is skipped.
private struct FileCard: View {
    let line: PastedLinks.Line
    let sheet: NewDownloadModel

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            FileTypeBadge(text: badge)
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                name
                if let problem = line.problem {
                    Text(problem).font(DowlioDesign.TypeRole.detail).foregroundStyle(Color(nsColor: .systemRed))
                } else if let status {
                    HStack(spacing: DowlioDesign.Spacing.sm) {
                        if status.tone == .neutral { ProgressView().controlSize(.small) }
                        Text(status.line).foregroundStyle(status.tone.color)
                        if let size { Text("· \(size)").foregroundStyle(.secondary).monospacedDigit() }
                        if inspection?.isNotSecure ?? (url?.scheme?.lowercased() == "http") {
                            Label("Not secure", systemImage: "lock.open.fill").foregroundStyle(Color(nsColor: .systemOrange))
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
        if sheet.isSingleLink, line.problem == nil {
            TextField("File name", text: Binding(get: { sheet.fileName }, set: { sheet.nameEdited($0) }))
                .textFieldStyle(.plain)
                .font(DowlioDesign.TypeRole.heading)
        } else {
            Text(title).font(DowlioDesign.TypeRole.heading).lineLimit(1).truncationMode(.middle)
        }
    }

    private var url: URL? {
        if case .link(let url) = line { url } else { nil }
    }

    private var check: NewDownloadModel.Check? { url.flatMap { sheet.checks[$0] } }

    private var status: LinkStatus? { check?.status }

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

    private var badge: String {
        (title as NSString).pathExtension.uppercased()
    }

    private var size: String? {
        inspection?.totalBytes.map(ByteText.string)
    }
}

extension LinkStatus.Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: Color(nsColor: .systemGreen)
        case .caution: Color(nsColor: .systemOrange)
        case .problem: Color(nsColor: .systemRed)
        }
    }
}
