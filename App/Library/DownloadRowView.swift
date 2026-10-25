import DowlioCore
import DowlioLibrary
import SwiftUI

struct DownloadRowView: View {
    let row: DownloadRow
    let actions: RowActions?

    var body: some View {
        HStack(alignment: .center, spacing: DowlioDesign.Spacing.md) {
            FileTypeBadge(text: row.badge)
            details
            action
        }
        .padding(.vertical, DowlioDesign.Spacing.xs)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                Text(row.fileName)
                    .font(DowlioDesign.TypeRole.heading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(row.stateWord, systemImage: row.state.symbolName)
                    .font(DowlioDesign.TypeRole.caption)
                    .foregroundStyle(row.state.tone)
                    .fixedSize()
                if row.isNotSecure {
                    Label("Not secure", systemImage: "lock.open.fill")
                        .font(DowlioDesign.TypeRole.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize()
                }
            }
            SegmentedBar(segments: row.displaySegments, fraction: row.fractionDone, tint: row.state.tone)
            HStack {
                Text(row.detailLine)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                if let speed = row.speedText { Text(speed) }
                if let timeLeft = row.timeLeftText { Text(timeLeft) }
            }
            .font(DowlioDesign.TypeRole.detailMetric)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenSummary)
    }

    private var action: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            primaryAction
            if row.canCancel {
                actionButton("Cancel and delete", symbol: "xmark") { actions?.cancel(row) }
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch row.state {
        case .downloading, .retrying, .queued:
            actionButton("Pause", symbol: "pause.fill") { actions?.pause(row) }
        case .paused:
            actionButton("Resume", symbol: "play.fill") { actions?.resume(row) }
                .disabled(row.lostSignIn)
        case .failed:
            actionButton("Retry", symbol: "arrow.clockwise") { actions?.retry(row) }
        case .completed:
            actionButton("Show in Finder", symbol: "magnifyingglass") { actions?.showInFinder(row) }
                .disabled(row.finishedFile == nil)
        }
    }

    private func actionButton(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct FileTypeBadge: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 44

    var body: some View {
        Text(text.isEmpty ? "FILE" : String(text.prefix(4)))
            .font(DowlioDesign.TypeRole.caption)
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .accessibilityHidden(true)
    }
}

#Preview("Rows, light") {
    RowPreview().preferredColorScheme(.light)
}

#Preview("Rows, dark") {
    RowPreview().preferredColorScheme(.dark)
}

private struct RowPreview: View {
    var body: some View {
        List(Self.rows) { DownloadRowView(row: $0, actions: nil) }
            .frame(width: 640, height: 320)
    }

    static let rows: [DownloadRow] = {
        let segments = (0..<8).map { index in
            SegmentProgress(start: Int64(index) * 400_000_000, end: Int64(index + 1) * 400_000_000 - 1,
                            receivedBytes: Int64(index) * 50_000_000 + 60_000_000, isActive: true)
        }
        var downloading = sample("ubuntu-24.04.iso", state: .downloading)
        downloading.segments = segments
        downloading.receivedBytes = segments.reduce(0) { $0 + $1.receivedBytes }
        downloading.totalBytes = 3_200_000_000
        downloading.activeConnections = 8
        downloading.bytesPerSecond = 42_000_000
        downloading.timeRemaining = 48
        var paused = sample("Quarterly Report.pdf", state: .paused)
        paused.receivedBytes = 1_200_000
        paused.totalBytes = 4_800_000
        paused.isNotSecure = true
        var completed = sample("Installer.dmg", state: .completed)
        completed.receivedBytes = 98_000_000
        completed.totalBytes = 98_000_000
        return [downloading, paused, sample("old-link.zip", state: .failed(.linkExpired)), completed]
    }()

    static func sample(_ name: String, state: DownloadRow.State) -> DownloadRow {
        DownloadRow(
            id: DownloadID(), state: state, fileName: name, sourceURL: URL(string: "https://example.com/\(name)")!,
            host: "example.com", folder: URL(filePath: "/tmp"), category: nil, receivedBytes: 0, totalBytes: nil,
            segments: [], activeConnections: 0, bytesPerSecond: 0, timeRemaining: nil, isNotSecure: false,
            canResume: true, addedAt: .now, completedAt: nil, isFileMissing: false, wasSkipped: false
        )
    }
}
