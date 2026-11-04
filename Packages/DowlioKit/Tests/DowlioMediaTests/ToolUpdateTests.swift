import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ToolUpdateTests {
    private func installed() async throws -> (FakeGitHub, ToolInstaller, URL) {
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.10.26", zip: try FakeGitHub.standInYTDLP(script: "echo old"))
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let folder = try TestFiles.makeFolder().appending(path: "Tools", directoryHint: .isDirectory)
        let installer = ToolInstaller(folder: folder, source: .testing(api: github.api))
        try await installer.install()
        return (github, installer, folder)
    }

    @Test func withNoNewerReleaseThereIsNothingToUpdate() async throws {
        let (github, installer, _) = try await installed()

        #expect(try await installer.checkForUpdate() == [])
        #expect(try await installer.update() == false)
        withExtendedLifetime(github) {}
    }

    @Test func aNewerStableReleaseInstallsWithTheSameChecksAndRecordsItsVersionAndHash() async throws {
        let (github, installer, folder) = try await installed()
        let before = try await installer.verifiedTools()
        github.publishYTDLP(version: "2026.11.03", zip: try FakeGitHub.standInYTDLP(script: "echo new"))

        #expect(try await installer.checkForUpdate() == [.ytdlp])
        #expect(try await installer.update() == true)

        #expect(await installer.installedVersions() == [.ytdlp: "2026.11.03", .quickJS: "v0.18.0"])
        let after = try await installer.verifiedTools()
        #expect(after == before)
        let script = try String(contentsOf: folder.appending(path: "yt-dlp/yt-dlp_macos"), encoding: .utf8)
        #expect(script.contains("echo new"))
    }

    @Test func anUpdateWhoseHashDoesntMatchLeavesTheInstalledToolWorking() async throws {
        let (github, installer, _) = try await installed()
        github.publishYTDLP(
            version: "2026.11.03", zip: try FakeGitHub.standInYTDLP(script: "echo new"), sums: "\(String(repeating: "1", count: 64))  yt-dlp_macos.zip\n"
        )

        await #expect(throws: ToolInstaller.Failure.hashMismatch(.ytdlp)) { try await installer.update() }

        #expect(await installer.installedVersions()[.ytdlp] == "2026.10.26")
        _ = try await installer.verifiedTools()
    }

    @Test func aPrereleaseIsNeverAnUpdate() async throws {
        let (github, installer, _) = try await installed()
        github.publishYTDLP(version: "2026.11.04.nightly", zip: try FakeGitHub.standInYTDLP(script: "echo nightly"), prerelease: true)

        await #expect(throws: ToolInstaller.Failure.notStable(.ytdlp)) { try await installer.checkForUpdate() }
        #expect(await installer.installedVersions()[.ytdlp] == "2026.10.26")
    }

    @Test func removeDeletesBothToolsAndTheirRecords() async throws {
        let (github, installer, folder) = try await installed()

        try await installer.remove()
        withExtendedLifetime(github) {}

        #expect(await installer.installedVersions().isEmpty)
        #expect(await installer.isInstalled == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "yt-dlp").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "qjs").path))
        await #expect(throws: ToolInstaller.Failure.notInstalled) { try await installer.verifiedTools() }
    }

    @Test func withUpdatesOnTheCheckIsDueWeeklyAndNeverWithThemOff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60

        #expect(ToolInstaller.isUpdateCheckDue(lastCheck: nil, now: now, keepsUpToDate: true))
        #expect(ToolInstaller.isUpdateCheckDue(lastCheck: now - 7 * day, now: now, keepsUpToDate: true))
        #expect(!ToolInstaller.isUpdateCheckDue(lastCheck: now - 6 * day, now: now, keepsUpToDate: true))
        #expect(!ToolInstaller.isUpdateCheckDue(lastCheck: nil, now: now, keepsUpToDate: false))
        #expect(!ToolInstaller.isUpdateCheckDue(lastCheck: now - 30 * day, now: now, keepsUpToDate: false))
    }
}
