import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ToolInstallerTests {
    private func installer(_ github: FakeGitHub) throws -> (ToolInstaller, URL) {
        let folder = try TestFiles.makeFolder().appending(path: "Tools", directoryHint: .isDirectory)
        return (ToolInstaller(folder: folder, source: .testing(api: github.api)), folder)
    }

    private func published() async throws -> FakeGitHub {
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.10.26", zip: try FakeGitHub.standInYTDLP(script: "echo listed"))
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        return github
    }

    @Test func bothToolsInstallWhenTheirHashesMatchAndRecordTheirVersions() async throws {
        let github = try await published()
        let (installer, folder) = try installer(github)

        try await installer.install()

        #expect(await installer.installedVersions() == [.ytdlp: "2026.10.26", .quickJS: "v0.18.0"])
        let tools = try await installer.verifiedTools()
        #expect(tools.ytdlp == folder.appending(path: "yt-dlp/yt-dlp_macos"))
        #expect(tools.quickJS == folder.appending(path: "qjs"))
        for tool in [tools.ytdlp, tools.quickJS] {
            let mode = try FileManager.default.attributesOfItem(atPath: tool.path)[.posixPermissions] as? Int
            #expect(mode == 0o755)
            #expect(getxattr(tool.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        }
    }

    @Test func theConsentPromptsSizeIsBothDownloadsTogether() async throws {
        let github = try await FakeGitHub()
        let zip = try FakeGitHub.standInYTDLP(script: "echo listed")
        github.publishYTDLP(version: "2026.10.26", zip: zip)
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let (installer, _) = try installer(github)

        let size = try await installer.downloadSize()

        #expect(size == Int64(zip.count + FakeGitHub.standInQuickJS().count))
    }

    @Test func aYTDLPWhoseHashDoesntMatchItsSumsFileIsRefused() async throws {
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.10.26", zip: try FakeGitHub.standInYTDLP(script: "echo listed"), sums: "\(String(repeating: "0", count: 64))  yt-dlp_macos.zip\n")
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let (installer, folder) = try installer(github)

        await #expect(throws: ToolInstaller.Failure.hashMismatch(.ytdlp)) { try await installer.install() }

        #expect(await installer.installedVersions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "yt-dlp").path))
    }

    @Test func aQuickJSWhoseDigestDoesntMatchIsRefused() async throws {
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.10.26", zip: try FakeGitHub.standInYTDLP(script: "echo listed"))
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS(), digest: FakeGitHub.digest(Data("something else".utf8)))
        let (installer, folder) = try installer(github)

        await #expect(throws: ToolInstaller.Failure.hashMismatch(.quickJS)) { try await installer.install() }

        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "qjs").path))
    }

    @Test func aRedirectOffGitHubsDownloadHostsIsRefused() async throws {
        let github = try await FakeGitHub()
        let elsewhere = try await TestServer()
        let zip = try FakeGitHub.standInYTDLP(script: "echo listed")
        github.publishYTDLP(version: "2026.10.26", zip: zip, redirectingDownloadsTo: URL(string: "http://localhost:\(elsewhere.port)")!)
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let (installer, _) = try installer(github)

        await #expect(throws: ToolInstaller.Failure.offGitHub) { try await installer.install() }

        #expect(elsewhere.requests.isEmpty)
        #expect(await installer.installedVersions().isEmpty)
    }

    @Test func aPrereleaseIsNeverInstalled() async throws {
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.11.01.nightly", zip: try FakeGitHub.standInYTDLP(script: "echo listed"), prerelease: true)
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let (installer, _) = try installer(github)

        await #expect(throws: ToolInstaller.Failure.notStable(.ytdlp)) { try await installer.install() }
    }

    @Test func aToolWhoseFilesChangedAfterInstallingIsRefused() async throws {
        let github = try await published()
        let (installer, folder) = try installer(github)
        try await installer.install()

        try Data("tampered".utf8).write(to: folder.appending(path: "yt-dlp/_internal/base_library.zip"))

        await #expect(throws: ToolInstaller.Failure.changed(.ytdlp)) { try await installer.verifiedTools() }
    }

    @Test func aReplacedQuickJSIsRefused() async throws {
        let github = try await published()
        let (installer, folder) = try installer(github)
        try await installer.install()

        try Data("#!/bin/sh\necho other\n".utf8).write(to: folder.appending(path: "qjs"))

        await #expect(throws: ToolInstaller.Failure.changed(.quickJS)) { try await installer.verifiedTools() }
    }

    @Test func aFileWhoseModeChangedIsRefused() async throws {
        let github = try await published()
        let (installer, folder) = try installer(github)
        try await installer.install()

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.appending(path: "qjs").path)

        await #expect(throws: ToolInstaller.Failure.changed(.quickJS)) { try await installer.verifiedTools() }
    }

    @Test func installingTwiceAtOnceInstallsOnce() async throws {
        let github = try await published()
        let (installer, _) = try installer(github)

        async let first: Void = installer.install()
        async let second: Void = installer.install()
        _ = try await (first, second)

        #expect(await installer.isInstalled)
        let apiCalls = github.server.requests.filter { $0.path == "/repos/yt-dlp/yt-dlp/releases/latest" }
        #expect(apiCalls.count == 1)
    }

    @Test func toolsThatArentInstalledAreReportedSo() async throws {
        let github = try await published()
        let (installer, _) = try installer(github)

        await #expect(throws: ToolInstaller.Failure.notInstalled) { try await installer.verifiedTools() }
        #expect(await installer.isInstalled == false)
    }
}
