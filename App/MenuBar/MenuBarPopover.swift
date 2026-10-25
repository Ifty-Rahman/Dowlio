import AppKit
import DowlioCore
import DowlioLibrary
import SwiftUI

struct MenuBarPopover: View {
    let model: AppModel
    @Bindable var panel: MenuBarPanel
    let close: () -> Void
    @State private var showsMore = false

    var body: some View {
        Group {
            if panel.showsQuickAdd {
                QuickAddView(model: model, panel: panel, close: close)
            } else {
                summary
            }
        }
        .padding(DowlioDesign.Spacing.lg)
        .frame(width: 320, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if showsMore {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showsMore = false }
                        .accessibilityHidden(true)
                    MoreMenu(
                        settings: { run(model.showSettings) },
                        reportProblem: { run(model.reportProblem) },
                        quit: { NSApp.terminate(nil) }
                    )
                    .padding(.top, DowlioDesign.Spacing.xxl + DowlioDesign.Spacing.lg)
                    .padding(.trailing, DowlioDesign.Spacing.md)
                }
            }
        }
        .onChange(of: panel.showsQuickAdd) { showsMore = false }
    }

    private func run(_ action: () -> Void) {
        showsMore = false
        close()
        action()
    }

    private var summary: some View {
        let summary = MenuBarSummary(rows: model.rows)
        return VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text("Dowlio").font(DowlioDesign.TypeRole.title).accessibilityAddTraits(.isHeader)
                    Text(summary.status).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                }
                Spacer()
                if let speed = summary.speedText {
                    Text(speed).font(DowlioDesign.TypeRole.detailMetric).foregroundStyle(.secondary)
                }
                moreMenu
            }
            if !summary.active.isEmpty {
                VStack(spacing: DowlioDesign.Spacing.sm) {
                    ForEach(summary.active) { row in
                        PopoverRow(row: row, model: model)
                    }
                    if summary.moreActive > 0 {
                        Text("and \(summary.moreActive) more")
                            .font(DowlioDesign.TypeRole.detail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Text("Catch browser downloads")
                    .accessibilityHidden(true)
                Spacer()
                Toggle("Catch browser downloads", isOn: catches)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Catch browser downloads")
            }
            HStack {
                Button("Pause All") { model.pauseAll() }
                    .disabled(!summary.canPauseAll)
                Button("Add Link…") { panel.showsQuickAdd = true }
                Spacer()
                Button("Open Dowlio") {
                    close()
                    model.showLibraryWindow()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var catches: Binding<Bool> {
        Binding(get: { model.catchPreferences.catches }, set: { model.catchPreferences.catches = $0 })
    }

    private var moreMenu: some View {
        Button { showsMore.toggle() } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.borderless)
        .help("More")
        .accessibilityLabel("More")
    }
}

/// Settings, Report a Problem and Quit, drawn inside the popover on its own material, so the
/// menu matches the popover and opens wherever the popover is.
private struct MoreMenu: View {
    let settings: () -> Void
    let reportProblem: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MoreMenuItem(title: "Settings…", shortcut: "⌘,", action: settings)
            MoreMenuItem(title: "Report a Problem", shortcut: nil, action: reportProblem)
            Divider().padding(.vertical, DowlioDesign.Spacing.xs)
            MoreMenuItem(title: "Quit Dowlio", shortcut: "⌘Q", action: quit)
        }
        .padding(DowlioDesign.Spacing.xs)
        .frame(width: 190)
        .popoverGlass()
        .clipShape(RoundedRectangle(cornerRadius: DowlioDesign.Radius.container))
        .overlay(RoundedRectangle(cornerRadius: DowlioDesign.Radius.container).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More")
    }
}

private struct MoreMenuItem: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(isHovered ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.vertical, DowlioDesign.Spacing.xs)
            .foregroundStyle(isHovered ? .white : .primary)
            .background(isHovered ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested - 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct PopoverRow: View {
    let row: DownloadRow
    let model: AppModel
    @State private var confirmsCancel = false

    @ViewBuilder private var cancelButton: some View {
        if confirmsCancel {
            Button("Delete", role: .destructive) { model.cancel(row) }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(DowlioDesign.TypeRole.caption)
                .help("Cancel and delete what's downloaded so far")
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    confirmsCancel = false
                }
        } else {
            Button("Cancel and delete", systemImage: "xmark") {
                if row.hasBytesAtStake { confirmsCancel = true } else { model.cancel(row) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Cancel and delete")
        }
    }

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                HStack {
                    Text(row.fileName).font(DowlioDesign.TypeRole.body).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: DowlioDesign.Spacing.xs)
                    Text(row.speedText ?? row.stateWord)
                        .font(DowlioDesign.TypeRole.caption.monospacedDigit())
                        .foregroundStyle(row.state.tone)
                }
                SegmentedBar(segments: row.displaySegments, fraction: row.fractionDone, tint: row.state.tone, height: 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.spokenSummary)
            if row.canPause {
                Button("Pause", systemImage: "pause.fill") { model.pause(row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Pause")
            } else if row.state == .paused, !row.lostCookies {
                Button("Resume", systemImage: "play.fill") { model.resume(row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Resume")
            }
            cancelButton
        }
        .accessibilityElement(children: .contain)
    }
}
