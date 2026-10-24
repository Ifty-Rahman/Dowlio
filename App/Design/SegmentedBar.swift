import DowlioCore
import SwiftUI

/// The brand motif: one piece per segment, each as wide as its share of the file and filled by
/// the bytes it has. A download of unknown size shows one piece.
struct SegmentedBar: View {
    let segments: [SegmentProgress]
    /// The whole download's fill, for a download with no segments yet.
    let fraction: Double?
    let tint: Color
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    pieceView(fill: piece.fill)
                        .frame(width: max(width(of: piece, in: proxy.size.width), height))
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: pieces)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private struct Piece: Equatable {
        var share: Double
        var fill: Double
    }

    private var gap: CGFloat { height / 2 }

    private var pieces: [Piece] {
        let total = segments.reduce(Int64(0)) { $0 + $1.length }
        guard total > 0 else { return [Piece(share: 1, fill: fraction ?? 0)] }
        return segments.map { segment in
            Piece(
                share: Double(segment.length) / Double(total),
                fill: segment.length > 0 ? min(Double(segment.receivedBytes) / Double(segment.length), 1) : 1
            )
        }
    }

    private func width(of piece: Piece, in available: CGFloat) -> CGFloat {
        let gaps = gap * CGFloat(max(pieces.count - 1, 0))
        return max(available - gaps, 0) * piece.share
    }

    private func pieceView(fill: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(tint).frame(width: proxy.size.width * fill)
            }
        }
    }

    private var accessibilityValue: String {
        let done = fraction ?? pieces.reduce(0) { $0 + $1.share * $1.fill }
        return "\(Int((done * 100).rounded(.down))) percent"
    }
}

private extension SegmentProgress {
    var length: Int64 { end - start + 1 }
}

#Preview("Segmented bar, light") {
    SegmentedBarPreview().preferredColorScheme(.light)
}

#Preview("Segmented bar, dark") {
    SegmentedBarPreview().preferredColorScheme(.dark)
}

private struct SegmentedBarPreview: View {
    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.lg) {
            SegmentedBar(segments: Self.eight, fraction: nil, tint: .accentColor)
            SegmentedBar(segments: Self.eight, fraction: nil, tint: Color(nsColor: .systemGray))
            SegmentedBar(segments: [], fraction: 0.4, tint: Color(nsColor: .systemGreen))
        }
        .padding(DowlioDesign.Spacing.xl)
        .frame(width: 360)
    }

    static let eight: [SegmentProgress] = (0..<8).map { index in
        let start = Int64(index) * 1000
        return SegmentProgress(start: start, end: start + 999, receivedBytes: Int64(index * 140), isActive: true)
    }
}
