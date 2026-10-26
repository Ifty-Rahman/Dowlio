import AppKit
import DowlioCore
import DowlioLibrary
import SwiftUI

struct MenuBarPopover: View {
    let model: AppModel
    @Bindable var panel: MenuBarPanel
    let close: () -> Void
    let toggleMore: () -> Void

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
            HStack(spacing: DowlioDesign.Spacing.sm) {
                Button { model.pauseAll() } label: { fullWidth("Pause All") }
                    .disabled(!summary.canPauseAll)
                Button { panel.showsQuickAdd = true } label: { fullWidth("Add Link…") }
                Button {
                    close()
                    model.showLibraryWindow()
                } label: { fullWidth("Open Dowlio") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func fullWidth(_ title: String) -> some View {
        Text(title).lineLimit(1).frame(maxWidth: .infinity)
    }

    private var catches: Binding<Bool> {
        Binding(get: { model.catchPreferences.catches }, set: { model.catchPreferences.catches = $0 })
    }

    private var moreMenu: some View {
        Button(action: toggleMore) {
            Image(systemName: "ellipsis.circle")
        }
        .background(MoreMenuAnchor { panel.moreAnchor = $0 })
        .buttonStyle(.borderless)
        .help("More")
        .accessibilityLabel("More")
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
