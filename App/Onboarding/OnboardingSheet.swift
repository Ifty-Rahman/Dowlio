import DowlioCore
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
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
            FillingBar()
                .padding(.top, DowlioDesign.Spacing.xl)
                .padding(.bottom, DowlioDesign.Spacing.lg)
            Text("Welcome to Dowlio")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Dowlio splits each download across several connections, so big files finish sooner. When a connection finishes early, it takes over half of the slowest one's remaining work.")
                .font(DowlioDesign.TypeRole.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

private struct FillingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let speeds: [Double] = [1.0, 0.8, 1.15, 0.7, 0.95, 1.25, 0.85, 1.05]
    private static let cycle: TimeInterval = 4

    var body: some View {
        Group {
            if reduceMotion {
                bar(at: Self.cycle)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    bar(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A download split across eight connections")
    }

    private func bar(at time: TimeInterval) -> some View {
        let segments = Self.speeds.enumerated().map { index, speed in
            let start = Int64(index * 100)
            let filled = min(time / (Self.cycle * 0.75) * speed, 1)
            return SegmentProgress(start: start, end: start + 99, receivedBytes: Int64(filled * 100), isActive: filled < 1)
        }
        return SegmentedBar(segments: segments, fraction: nil, tint: DowlioDesign.brandAccent, height: 8)
    }
}
