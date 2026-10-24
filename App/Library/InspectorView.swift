import DowlioCore
import DowlioLibrary
import SwiftUI

/// The selected download in depth: percentage, segments, speed, time left, whether it can resume,
/// and where it comes from.
struct InspectorView: View {
    let row: DownloadRow?
    let actions: RowActions?

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        Text(percentText(row))
                            .font(DowlioDesign.TypeRole.heroMetric)
                        Label(row.stateWord, systemImage: row.state.symbolName)
                            .font(DowlioDesign.TypeRole.caption)
                            .foregroundStyle(row.state.tone)
                        Text(row.fileName)
                            .font(DowlioDesign.TypeRole.heading)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if !row.segments.isEmpty {
                        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                            Text("Segments · \(row.segmentCountText)")
                                .font(DowlioDesign.TypeRole.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            ForEach(Array(row.segments.enumerated()), id: \.offset) { _, segment in
                                SegmentedBar(segments: [segment], fraction: nil, tint: segment.isActive ? row.state.tone : .secondary, height: 4)
                            }
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.sm) {
                        fact("Speed", row.speedText ?? "—")
                        fact("Time left", row.timeLeftText ?? "—")
                        fact("Size", row.detailLine)
                        fact("Resumable", resumableText(row))
                        if let taken = row.timeTakenText { fact("Time taken", taken) }
                        fact("From", row.host ?? "—")
                        if row.isNotSecure { fact("Connection", "Not secure") }
                    }
                    .font(DowlioDesign.TypeRole.detailMetric)
                    HStack {
                        Button("Show in Finder") { actions?.showInFinder(row) }
                            .disabled(row.finishedFile == nil)
                        Button("Copy Link") { actions?.copyLink(row) }
                    }
                }
                .padding(DowlioDesign.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(NoScrollEdgeEffect())
        } else {
            ContentUnavailableView("No download selected", systemImage: "sidebar.right")
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func percentText(_ row: DownloadRow) -> String {
        row.fractionDone.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "—"
    }

    private func resumableText(_ row: DownloadRow) -> String {
        if row.state == .completed { return "—" }
        return row.canResume ? "Yes" : "No, pausing starts it over"
    }
}

/// Several downloads selected: how many, their combined size and speed.
struct SelectionInspector: View {
    let rows: [DownloadRow]
    let actions: RowActions

    var body: some View {
        let summary = SelectionSummary(rows: rows)
        ScrollView {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
                Text(summary.title)
                    .font(DowlioDesign.TypeRole.heroMetric)
                Grid(alignment: .leading, horizontalSpacing: DowlioDesign.Spacing.md, verticalSpacing: DowlioDesign.Spacing.sm) {
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(summary.sizeText)
                    }
                    GridRow {
                        Text("Speed").foregroundStyle(.secondary)
                        Text(summary.speedText ?? "—")
                    }
                }
                .font(DowlioDesign.TypeRole.detailMetric)
                HStack {
                    Button("Show in Finder") { actions.showInFinder(rows) }
                        .disabled(summary.finishedFiles.isEmpty)
                    Button("Copy Links") { actions.copyLinks(rows) }
                }
            }
            .padding(DowlioDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(NoScrollEdgeEffect())
    }
}

#Preview("Inspector, light") {
    InspectorView(row: InspectorPreview.row, actions: nil).frame(width: 280, height: 480).preferredColorScheme(.light)
}

#Preview("Inspector, dark") {
    InspectorView(row: InspectorPreview.row, actions: nil).frame(width: 280, height: 480).preferredColorScheme(.dark)
}

private enum InspectorPreview {
    static let segments: [SegmentProgress] = (0..<6).map { (index: Int) -> SegmentProgress in
        let start = Int64(index) * 1_000_000
        return SegmentProgress(start: start, end: start + 999_999, receivedBytes: Int64(index) * 150_000 + 100_000, isActive: index % 2 == 0)
    }

    static let row: DownloadRow = {
        let received: Int64 = segments.reduce(0) { $0 + $1.receivedBytes }
        return DownloadRow(
            id: DownloadID(), state: .downloading, fileName: "ubuntu-24.04-desktop-amd64.iso",
            sourceURL: URL(string: "https://releases.ubuntu.com/ubuntu.iso")!, host: "releases.ubuntu.com",
            folder: URL(filePath: "/tmp"), category: .appsAndDiskImages,
            receivedBytes: received, totalBytes: 6_000_000, segments: segments,
            activeConnections: 3, bytesPerSecond: 12_400_000, timeRemaining: 94, isNotSecure: false, canResume: true,
            addedAt: .now, completedAt: nil, isFileMissing: false, wasSkipped: false
        )
    }()
}
