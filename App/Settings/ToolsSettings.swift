import DowlioMedia
import Observation
import SwiftUI

@MainActor
@Observable
final class ToolsModel {
    private(set) var versions: [Tool: String] = [:]
    private(set) var isBusy = false
    private(set) var status: String?
    private let installer: ToolInstaller
    @ObservationIgnored private var weekly: Task<Void, Never>?

    init(installer: ToolInstaller) {
        self.installer = installer
    }

    var isInstalled: Bool { !versions.isEmpty }

    func refresh() async {
        versions = await installer.installedVersions()
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

struct ToolsSection: View {
    let tools: ToolsModel
    @AppStorage(SettingsKey.keepsYTDLPUpToDate) private var keepsUpToDate = true
    @State private var confirmingRemove = false

    var body: some View {
        Section("yt-dlp") {
            ForEach(Tool.allCases, id: \.self) { tool in
                LabeledContent {
                    Text(tools.versions[tool] ?? "Not installed").foregroundStyle(.secondary)
                } label: {
                    Link(destination: tool.project) {
                        Label {
                            Text(tool.name)
                        } icon: {
                            Image("GitHubMark").resizable().frame(width: 12, height: 12)
                        }
                    }
                    .help(tool.project.absoluteString)
                }
            }
            Toggle("Keep yt-dlp up to date", isOn: $keepsUpToDate)
            LabeledContent {
                HStack {
                    if tools.isBusy { ProgressView().controlSize(.small) }
                    Button("Check for Update") { tools.checkForUpdate() }
                        .disabled(tools.isBusy || !tools.isInstalled)
                    Button("Remove…") { confirmingRemove = true }
                        .disabled(tools.isBusy || !tools.isInstalled)
                }
            } label: {
                Text(tools.status ?? "yt-dlp reads YouTube and other sites. QuickJS-NG runs YouTube's scripts for it.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
