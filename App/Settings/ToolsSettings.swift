import DowlioMedia
import Observation
import SwiftUI

@MainActor
@Observable
final class ToolsModel {
    private(set) var versions: [Tool: String] = [:]
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var downloadSize: Int64?
    private let installer: ToolInstaller
    @ObservationIgnored private var weekly: Task<Void, Never>?

    init(installer: ToolInstaller) {
        self.installer = installer
    }

    var isInstalled: Bool { !versions.isEmpty }

    func refresh() async {
        versions = await installer.installedVersions()
        if versions.isEmpty, downloadSize == nil {
            downloadSize = try? await installer.downloadSize()
        }
    }

    var sizeText: String {
        guard let downloadSize else { return "From GitHub" }
        return "About \(max(Int((Double(downloadSize) / 1_000_000).rounded()), 1)) MB from GitHub"
    }

    func install() {
        run { installer in
            try await installer.install()
            let versions = await installer.installedVersions()
            return "Installed yt-dlp \(versions[.ytdlp] ?? "") and QuickJS-NG \(versions[.quickJS] ?? "")."
        }
    }

    func checkForUpdate() {
        run { installer in
            if try await installer.update() {
                let version = await installer.installedVersions()[.ytdlp] ?? ""
                return "Updated. yt-dlp is now \(version)."
            }
            return "yt-dlp and QuickJS-NG are up to date."
        }
    }

    func remove() {
        run { installer in
            try await installer.remove()
            return "Removed. Dowlio asks before downloading them again."
        }
    }

    private func run(_ work: @escaping @Sendable (ToolInstaller) async throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        status = nil
        let installer = installer
        Task {
            do {
                status = try await work(installer)
            } catch {
                status = Self.sentence(for: error)
            }
            await refresh()
            isBusy = false
        }
    }

    private static func sentence(for error: Error) -> String {
        switch error as? ToolInstaller.Failure {
        case .hashMismatch(let tool)?: "\(tool.name) didn't match the hash GitHub published, so Dowlio didn't install it."
        case .notStable(let tool)?: "The latest \(tool.name) release isn't a stable one, so Dowlio kept the one it has."
        case .offGitHub?: "A download tried to leave GitHub, so Dowlio stopped it."
        case .network?, .missingAsset?: "Dowlio couldn't reach GitHub. Try again later."
        default: "Dowlio couldn't change the tools on this Mac. Try again."
        }
    }

    func startWeeklyChecks() {
        guard weekly == nil else { return }
        let installer = installer
        weekly = Task {
            while !Task.isCancelled {
                let keeps = UserDefaults.standard.object(forKey: SettingsKey.keepsYTDLPUpToDate) as? Bool ?? true
                let last = await installer.lastUpdateCheck
                if await installer.isInstalled, ToolInstaller.isUpdateCheckDue(lastCheck: last, now: Date(), keepsUpToDate: keeps) {
                    _ = try? await installer.update()
                    await refresh()
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }
}

enum ToolsText {
    static let title = "Tools"
    static let info = "YouTube and many other sites hide their videos behind players, signed links and scripts. "
        + "yt-dlp, a free open-source tool, reads those sites and tells Dowlio where each video is. "
        + "QuickJS-NG runs the scripts YouTube uses, so yt-dlp can read it. "
        + "Dowlio downloads both from their official GitHub releases, checks each against the hash published there, "
        + "and never runs a copy that has changed. Dowlio still downloads every video itself."
}

struct ToolsInfoTitle: View {
    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.xs) {
            Text(ToolsText.title)
            InfoButton(topic: ToolsText.title, text: ToolsText.info)
        }
    }
}

struct ToolsRows: View {
    let tools: ToolsModel
    @AppStorage(SettingsKey.keepsYTDLPUpToDate) private var keepsUpToDate = true
    @State private var confirmingRemove = false

    var body: some View {
        ForEach(Tool.allCases, id: \.self) { tool in
            LabeledContent {
                Text(tools.versions[tool] ?? "Not installed")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    Text(tool.name)
                    Link(destination: tool.project) {
                        Image("GitHubMark").resizable().frame(width: 12, height: 12)
                    }
                    .foregroundStyle(.secondary)
                    .help("Open \(tool.name) on GitHub")
                    .accessibilityLabel("\(tool.name) on GitHub")
                }
                Text(tool == .ytdlp ? "Reads YouTube and other sites" : "Runs YouTube's scripts for yt-dlp")
            }
        }
        Toggle("Keep yt-dlp up to date", isOn: $keepsUpToDate)
        LabeledContent {
            HStack {
                if tools.isBusy { ProgressView().controlSize(.small) }
                if tools.isInstalled {
                    Button("Check for Update") { tools.checkForUpdate() }
                    Button("Remove…") { confirmingRemove = true }
                } else {
                    Button("Download and Install") { tools.install() }
                }
            }
            .disabled(tools.isBusy)
        } label: {
            Text(tools.status ?? (tools.isInstalled ? "Installed in Dowlio's own folder" : tools.sizeText))
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await tools.refresh() }
        .alert("Remove yt-dlp and QuickJS-NG?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { tools.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Partly downloaded videos stay. Dowlio asks before downloading the tools again.")
        }
    }
}
