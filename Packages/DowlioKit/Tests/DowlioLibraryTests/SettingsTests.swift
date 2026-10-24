import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

/// How Settings turn into what a download does, and the rules Settings keep.
struct SettingsTests {
    private let folder = URL(filePath: "/tmp/Downloads", directoryHint: .isDirectory)

    @Test func theDefaultsAreTheOnesSettingsShows() {
        let settings = DownloadSettings(folder: folder)
        #expect(settings.connections == 8)
        #expect(settings.downloadsAtOnce == 3)
        #expect(settings.retries == 5)
        #expect(settings.openExtraConnections == .afterFirstConnectionStarts)
        #expect(settings.nameConflictPolicy == .keepBoth)
        #expect(!settings.sortsIntoCategoryFolders)
        #expect(!settings.takesOverSlowSegments)
        #expect(!settings.options(connections: nil).allowsWorkStealing)
    }

    @Test func takingOverSlowSegmentsTurnsWorkStealingOn() {
        var settings = DownloadSettings(folder: folder)
        settings.takesOverSlowSegments = true
        #expect(settings.options(connections: nil).allowsWorkStealing)
    }

    /// "Retry a failed connection 5 times" means a sixth failure in a row fails the download.
    @Test(arguments: [(0, 1), (1, 2), (5, 6), (10, 11), (-3, 1), (40, 11)])
    func retriesBecomeTheFailuresTheEngineAllows(retries: Int, failures: Int) {
        var settings = DownloadSettings(folder: folder)
        settings.retries = retries
        #expect(settings.maximumFailures == failures)
    }

    @Test func theOptionsCarryEverySetting() {
        var settings = DownloadSettings(folder: folder)
        settings.connections = 12
        settings.retries = 2
        settings.openExtraConnections = .allAtOnce
        settings.nameConflictPolicy = .skip

        let options = settings.options(connections: nil)
        #expect(options.connections == 12)
        #expect(options.maximumFailures == 3)
        #expect(options.openExtraConnections == .allAtOnce)
        #expect(options.nameConflictPolicy == .skip)
        #expect(settings.options(connections: 4).connections == 4)
    }

    @Test(arguments: [(0, 1), (8, 8), (16, 16), (30, 16)])
    func theConnectionSettingStaysBetweenOneAndSixteen(value: Int, kept: Int) {
        var settings = DownloadSettings(folder: folder)
        settings.connections = value
        #expect(settings.options(connections: nil).connections == kept)
    }

    @Test func categoryFoldersChangeTheDestination() {
        var settings = DownloadSettings(folder: folder)
        #expect(settings.destination(in: folder) == .folder(folder))
        settings.sortsIntoCategoryFolders = true
        #expect(settings.destination(in: folder) == .categoryFolders(under: folder))
    }

    @Test(arguments: [
        (Presence(menuBar: true, dock: true), Presence.Switch.menuBar, false, Presence(menuBar: false, dock: true), false),
        (Presence(menuBar: false, dock: true), .dock, false, Presence(menuBar: true, dock: false), true),
        (Presence(menuBar: true, dock: false), .menuBar, false, Presence(menuBar: false, dock: true), true),
        (Presence(menuBar: false, dock: true), .menuBar, true, Presence(menuBar: true, dock: true), false),
    ])
    func dowlioAlwaysStaysInTheMenuBarOrTheDock(
        before: Presence, toggled: Presence.Switch, isOn: Bool, after: Presence, explains: Bool
    ) {
        let result = before.setting(toggled, to: isOn)
        #expect(result.presence == after)
        #expect((result.note != nil) == explains)
    }

    @Test func startingInTheMenuBarKeepsTheMenuBarIconOn() {
        let result = Presence(menuBar: false, dock: true).setting(.startsInMenuBar, to: true)
        #expect(result.presence == Presence(menuBar: true, dock: true, startsInMenuBar: true))
        #expect(result.note == nil)
    }

    @Test func theMenuBarIconCantBeTurnedOffWhileDowlioStartsThere() {
        let starting = Presence(menuBar: true, dock: true, startsInMenuBar: true)
        #expect(starting.setting(.menuBar, to: false).presence == starting)
        #expect(!starting.canChangeMenuBar)
        #expect(Presence(menuBar: true, dock: true).canChangeMenuBar)
    }

    @Test func turningOffStartInTheMenuBarLeavesTheIconAsItIs() {
        let result = Presence(menuBar: true, dock: false, startsInMenuBar: true).setting(.startsInMenuBar, to: false)
        #expect(result.presence == Presence(menuBar: true, dock: false, startsInMenuBar: false))
    }

    @Test(arguments: [
        (false, false, true),
        (true, false, false),
        (false, true, false),
        (true, true, false),
    ])
    func theWindowOpensAtLaunchUnlessDowlioStartsInTheMenuBarOrAtLogin(startsInMenuBar: Bool, atLogin: Bool, opens: Bool) {
        let presence = Presence(menuBar: true, dock: true, startsInMenuBar: startsInMenuBar)
        #expect(presence.opensWindowAtLaunch(launchedAtLogin: atLogin) == opens)
    }

    @Test(arguments: [
        (2, "Stop 2 downloads and quit?"),
        (1, "Stop 1 download and quit?"),
    ])
    func theQuitGuardCountsWhatWouldStop(count: Int, title: String) {
        let rows = (0..<count).map { _ in Self.row(.downloading) } + [Self.row(.paused), Self.row(.completed)]
        #expect(QuitGuard(rows: rows)?.title == title)
        #expect(QuitGuard(rows: rows)?.message == "They can resume next time.")
    }

    @Test func quittingWithNothingRunningOrWaitingNeedsNoQuestion() {
        #expect(QuitGuard(rows: [Self.row(.paused), Self.row(.failed(.notFound)), Self.row(.completed)]) == nil)
        #expect(QuitGuard(rows: [Self.row(.queued)])?.title == "Stop 1 download and quit?")
    }

    private static func row(_ state: DownloadRow.State) -> DownloadRow {
        DownloadRow(
            id: DownloadID(), state: state, fileName: "a.zip", sourceURL: URL(string: "https://example.com/a.zip")!,
            host: "example.com", folder: URL(filePath: "/tmp"), category: nil, receivedBytes: 0, totalBytes: nil,
            segments: [], activeConnections: 0, bytesPerSecond: 0, timeRemaining: nil, isNotSecure: false,
            canResume: true, addedAt: Date(), completedAt: nil, isFileMissing: false, wasSkipped: false
        )
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SettingsAtRelaunchTests {
    /// A download brought back after a relaunch takes the retry setting in force then, not the
    /// one it was added with.
    @Test func aRestoredDownloadTakesTheRetrySettingInForceAtLaunch() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 600)
        server.serve(.init(data: data, eTag: "\"s1\"", dropFirst: .init(afterBytes: 256 * 1024, count: 3)), at: "/later.bin")
        var options = RequestOptions()
        options.connections = 1
        options.maximumFailures = 1

        let id = await fixture.add(server.url(for: "/later.bin"), options: options)
        _ = try await fixture.library.row(id) { $0.stateWord == "Failed" }

        let relaunched = try await fixture.relaunched(maximumFailures: 11)
        await relaunched.library.resume(id)
        _ = try await relaunched.library.row(id) { $0.state == .completed }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "later.bin")) == TestFiles.sha256(data))
    }
}
