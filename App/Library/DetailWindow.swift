import Charts
import DowlioCore
import DowlioLibrary
import SwiftUI

/// One download watched closely: its segments and the speed over the last minute, measured while
/// this window is open.
struct DetailWindow: View {
    static let sceneID = "download-detail"

    let id: DownloadID
    let model: AppModel
    @State private var history = SpeedHistory()

    var body: some View {
        Group {
            if let row = model.row(id) {
                content(row)
            } else {
                ContentUnavailableView("This download is no longer in the list", systemImage: "tray")
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task(id: id) { await sample() }
    }

    private func content(_ row: DownloadRow) -> some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            HStack(spacing: DowlioDesign.Spacing.md) {
                FileTypeBadge(text: row.badge)
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text(row.fileName).font(DowlioDesign.TypeRole.title).lineLimit(1).truncationMode(.middle)
                    Label(row.stateWord, systemImage: row.state.symbolName)
                        .font(DowlioDesign.TypeRole.caption)
                        .foregroundStyle(row.state.tone)
                }
            }
            SegmentedBar(segments: row.segments, fraction: row.fractionDone, tint: row.state.tone, height: 10)
            Text(row.detailLine).font(DowlioDesign.TypeRole.detailMetric).foregroundStyle(.secondary)
            speedChart
            Table(row.segments.enumerated().map { SegmentLine(number: $0.offset + 1, segment: $0.element) }) {
                TableColumn("Segment") { Text("\($0.number)").monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Starts at") { line in
                    Text(ByteText.string(line.segment.start)).monospacedDigit()
                }
                TableColumn("Size") { line in
                    Text(ByteText.string(line.size)).monospacedDigit()
                }
                TableColumn("Received") { line in
                    Text(ByteText.string(line.segment.receivedBytes)).monospacedDigit()
                }
                TableColumn("Connection") { line in
                    Text(line.status).foregroundStyle(line.segment.isActive ? .primary : .secondary)
                }
            }
        }
        .padding(DowlioDesign.Spacing.xl)
    }

    private var speedChart: some View {
        Chart(Array(history.samples.enumerated()), id: \.offset) { _, sample in
            AreaMark(x: .value("Seconds ago", -sample.secondsAgo), y: .value("Speed", sample.bytesPerSecond))
                .foregroundStyle(Color.accentColor.opacity(0.25))
            LineMark(x: .value("Seconds ago", -sample.secondsAgo), y: .value("Speed", sample.bytesPerSecond))
                .foregroundStyle(Color.accentColor)
        }
        .chartXScale(domain: -SpeedHistory.span...0)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { Text(value.as(Int64.self).map { "\(ByteText.string($0))/s" } ?? "") }
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Speed over the last minute")
        .accessibilityValue(history.peak > 0 ? "Peak \(ByteText.string(history.peak))/s" : "No speed measured yet")
    }

    private struct SegmentLine: Identifiable {
        let number: Int
        let segment: SegmentProgress
        var id: Int { number }
        var size: Int64 { segment.end - segment.start + 1 }
        var status: String {
            if segment.isActive { return "Active" }
            return segment.receivedBytes >= size ? "Done" : "Waiting"
        }
    }

    private func sample() async {
        while !Task.isCancelled {
            if let row = model.row(id) { history.record(row.bytesPerSecond, at: .now) }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
