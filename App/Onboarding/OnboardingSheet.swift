import AppKit
import DowlioCore
import DowlioLibrary
import SwiftUI

/// The welcome a fresh install shows: two pages, each with Skip. Later phases add the browser and
/// shortcut pages.
struct OnboardingSheet: View {
    let model: AppModel
    let finish: () -> Void
    @State private var page = DebugLaunch.opensOnboardingSetup ? Page.setup : Page.welcome

    enum Page: Int, CaseIterable {
        case welcome
        case setup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xl) {
            Group {
                switch page {
                case .welcome: WelcomePage()
                case .setup: SetupPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            if page == .welcome {
                FillingBar()
            }
            HStack {
                PageDots(current: page.rawValue, count: Page.allCases.count)
                Spacer()
                Button("Skip", action: finish)
                if page != .welcome {
                    Button("Back") { page = .welcome }
                }
                Button(page == .setup ? "Get Started" : "Continue") {
                    if page == .setup { finish() } else { page = .setup }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DowlioDesign.Spacing.xxl)
        .frame(width: 480)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Dowlio")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("A fast, reliable, native download manager for your Mac. Download fast with multiple connections, categorize into folders, capture from browser or send to the app.")
                .font(DowlioDesign.TypeRole.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DowlioDesign.Spacing.lg)
    }
}

private struct SetupPage: View {
    let model: AppModel
    @AppStorage(SettingsKey.downloadFolder) private var folderPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage(SettingsKey.sortsIntoCategoryFolders) private var sortsIntoCategoryFolders = false
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            Text("Where should downloads go?")
                .font(DowlioDesign.TypeRole.title)
                .accessibilityAddTraits(.isHeader)
            Form {
                LabeledContent("Download folder") {
                    HStack {
                        Text((folderPath as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                Toggle("Sort into category folders (Video, Audio, Documents…)", isOn: $sortsIntoCategoryFolders)
                PresenceToggles(model: model)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { folderPath = folder.path }
        }
    }
}

private struct PageDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// A pretend download: eight segments finishing at their own random pace within eight seconds,
/// then the bar turns green for two, and a new download starts. Still and full with Reduce Motion.
private struct FillingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let cycle: TimeInterval = 10
    private static let fillTime: TimeInterval = 8
    private static let count = 8

    var body: some View {
        Group {
            if reduceMotion {
                SegmentedBar(segments: Self.segments(filled: Array(repeating: 1, count: Self.count)), fraction: nil, tint: DowlioDesign.brandAccent, height: 8)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let filled = Self.fills(round: Int(time / Self.cycle), at: time.truncatingRemainder(dividingBy: Self.cycle))
                    let done = filled.allSatisfy { $0 >= 1 }
                    SegmentedBar(
                        segments: Self.segments(filled: filled), fraction: nil,
                        tint: done ? DownloadRow.State.completed.tone : DowlioDesign.brandAccent, height: 8
                    )
                    .animation(.easeInOut(duration: 0.3), value: done)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A download split across eight connections")
    }

    /// Each round gets its own random finish time and pace per segment, the same every time that
    /// round is drawn.
    private static func fills(round: Int, at time: TimeInterval) -> [Double] {
        var random = SplitMix(seed: UInt64(truncatingIfNeeded: round))
        return (0..<count).map { _ in
            let finish = 2.5 + random.next() * (fillTime - 2.5)
            let pace = 0.55 + random.next() * 1.1
            return pow(min(time / finish, 1), pace)
        }
    }

    private static func segments(filled: [Double]) -> [SegmentProgress] {
        filled.enumerated().map { index, fill in
            let start = Int64(index * 1000)
            return SegmentProgress(start: start, end: start + 999, receivedBytes: Int64(fill * 1000), isActive: fill < 1)
        }
    }
}

/// A tiny seeded random generator, so a round of the animation looks the same frame to frame.
private struct SplitMix {
    private var state: UInt64

    /// The seed is scrambled first, so neighbouring rounds don't share their numbers.
    init(seed: UInt64) {
        state = Self.mix(seed)
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Double(Self.mix(state) >> 11) / Double(1 << 53)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
