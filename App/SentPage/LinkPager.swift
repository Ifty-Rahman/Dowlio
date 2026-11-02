import DowlioCore
import DowlioLibrary
import SwiftUI

struct LinkPager: View {
    let sheet: NewDownloadModel
    @Binding var makesDefaultQuality: Bool
    var boxed = false

    var body: some View {
        let list = sheet.list
        if let item = list.current {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    PagerArrow(systemImage: "chevron.left", label: "Previous", isEnabled: list.position > 0) { list.previous() }
                    Text(list.positionLine)
                        .font(DowlioDesign.TypeRole.detail.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    PagerArrow(systemImage: "chevron.right", label: "Next", isEnabled: list.position < list.items.count - 1) { list.next() }
                    Spacer(minLength: DowlioDesign.Spacing.sm)
                    Toggle(item.includeLabel, isOn: Binding(get: { list.isIncluded(item.id) }, set: { list.include(item.id, $0) }))
                        .toggleStyle(.checkbox)
                        .font(DowlioDesign.TypeRole.detail)
                        .disabled(item.isRestricted)
                }
                LinkItemBody(sheet: sheet, item: item, makesDefaultQuality: $makesDefaultQuality, boxed: boxed)
                if item.savesAFile {
                    TextField("File name", text: Binding(get: { sheet.fileName(of: item) }, set: { sheet.rename(item, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("File name")
                }
            }
            .showsInList(item, of: list)
        }
    }
}

extension View {
    func showsInList(_ item: LinkItem, of list: LinkList) -> some View {
        task(id: item.id) { list.show(list.position) }
    }
}

struct LinkItemBody: View {
    let sheet: NewDownloadModel
    let item: LinkItem
    @Binding var makesDefaultQuality: Bool
    var boxed = false

    var body: some View {
        switch item.kind {
        case .checking(let url):
            LinkCard(url: url, check: sheet.draft.check(for: url))
        case .file(let url, let check):
            LinkCard(url: url, check: check ?? sheet.draft.check(for: url))
        case .page(let page):
            switch page.draft.phase {
            case .needsSignIn:
                NeedsSignInBody(media: page)
            case .blocked:
                BlockedBody(media: page)
            case .nothingFound:
                NothingFoundBody(media: page)
                LinkCard(url: page.draft.page.url, check: sheet.draft.check(for: page.draft.page.url))
            default:
                HStack(spacing: DowlioDesign.Spacing.md) {
                    InitialTile(host: page.draft.host).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        Text(page.draft.page.title ?? page.draft.host).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                        LookingLine(media: page)
                    }
                }
            }
        case .video(let page, let index):
            if page.draft.selected == index {
                MediaHeader(media: page)
                MediaChoices(media: page, makesDefaultQuality: $makesDefaultQuality, boxed: boxed)
            }
        }
    }
}

private struct PagerArrow: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(isHovered && isEnabled ? 0.25 : 0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

@MainActor
extension LinkItem {
    var includeLabel: String {
        switch kind {
        case .video: "Include this video"
        case .page(let page) where page.draft.phase == .looking || page.draft.phase == .playing: "Include this video"
        default: "Include this file"
        }
    }

    var isRestricted: Bool {
        if case .video(let page, let index) = kind { page.draft.candidates[index].restriction != nil } else { false }
    }

    var savesAFile: Bool {
        switch kind {
        case .checking: false
        case .file: true
        case .page(let page): page.draft.phase == .nothingFound
        case .video(let page, let index): page.draft.candidates[index].restriction == nil && !page.draft.candidates[index].versions.isEmpty
        }
    }
}

struct LinkCard: View {
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
