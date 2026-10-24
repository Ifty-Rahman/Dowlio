import AppKit
import DowlioCore
import DowlioLibrary
import SwiftUI

struct MenuBarPopover: View {
    let model: AppModel
    @Bindable var panel: MenuBarPanel
    let close: () -> Void

    var body: some View {
        Group {
            if panel.showsQuickAdd {
                QuickAddView(model: model, close: close) { panel.showsQuickAdd = false }
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
                VStack(alignment: .leading, spacing: 2) {
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
                Button("Pause All") { model.pauseAll() }
                    .disabled(!LibraryView(rows: model.rows, selection: .filter(.all), search: "").canPauseAll)
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

    private var moreMenu: some View {
        Menu {
            Button("Settings…") {
                close()
                model.showSettings()
            }
            Button("Report a Problem") {
                close()
                model.reportProblem()
            }
            Divider()
            Button("Quit Dowlio") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}

private struct PopoverRow: View {
    let row: DownloadRow
    let model: AppModel

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
                SegmentedBar(segments: row.segments, fraction: row.fractionDone, tint: row.state.tone, height: 3)
            }
            if row.canPause {
                Button("Pause", systemImage: "pause.fill") { model.pause(row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Pause")
            } else if row.state == .paused {
                Button("Resume", systemImage: "play.fill") { model.resume(row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Resume")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
