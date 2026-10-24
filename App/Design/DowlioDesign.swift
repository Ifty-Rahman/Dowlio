import DowlioLibrary
import SwiftUI

/// Dowlio's design tokens, from design.md. Colours are the accent asset or semantic system
/// colours, and text uses macOS text styles, never fixed sizes.
enum DowlioDesign {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let container: CGFloat = 12
        static let nested: CGFloat = 8
    }

    /// The metric styles use monospaced digits, so numbers that change don't jitter.
    enum TypeRole {
        static var title: Font { .title3.weight(.semibold) }
        static var heading: Font { .headline }
        static var body: Font { .body }
        static var detail: Font { .callout }
        static var caption: Font { .caption.weight(.semibold) }
        static var detailMetric: Font { detail.monospacedDigit() }
        static var heroMetric: Font { .largeTitle.weight(.bold).monospacedDigit() }
    }

    /// Dowlio Blue, whatever the system accent is. For brand art; controls use `Color.accentColor`.
    static var brandAccent: Color { Color("AccentColor") }
}

/// A download state's colour, word and icon. Colour never carries meaning alone.
extension DownloadRow.State {
    var tone: Color {
        switch self {
        case .downloading: .accentColor
        case .queued, .paused: Color(nsColor: .systemGray)
        case .retrying: Color(nsColor: .systemOrange)
        case .completed: Color(nsColor: .systemGreen)
        case .failed: Color(nsColor: .systemRed)
        }
    }

    var symbolName: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .queued: "clock.fill"
        case .paused: "pause.circle.fill"
        case .retrying: "arrow.clockwise.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

#Preview("Tokens, light") {
    TokenPreview().preferredColorScheme(.light)
}

#Preview("Tokens, dark") {
    TokenPreview().preferredColorScheme(.dark)
}

private struct TokenPreview: View {
    private let states: [DownloadRow.State] = [
        .downloading, .queued, .paused, .retrying(attempt: 2, nextTry: .now), .completed, .failed(.notFound),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            Text("Dowlio").font(DowlioDesign.TypeRole.title).foregroundStyle(DowlioDesign.brandAccent)
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Label(String(describing: state), systemImage: state.symbolName)
                    .foregroundStyle(state.tone)
                    .font(DowlioDesign.TypeRole.detail)
            }
        }
        .padding(DowlioDesign.Spacing.xl)
    }
}
