import DowlioConnect
import DowlioStore
import DowlioTestSupport
import Foundation
import Testing

struct BrowserScanTests {
    private func app(_ name: String, framework: String?, in folder: URL) throws {
        let frameworks = folder.appending(path: "\(name).app/Contents/Frameworks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if let framework {
            try FileManager.default.createDirectory(at: frameworks.appending(path: framework), withIntermediateDirectories: true)
        }
    }

    @Test func browsersThatBundleTheirOwnChromiumOrArcCoreAreFoundAndOtherAppsArent() throws {
        let applications = try TestFiles.makeFolder()
        let userApplications = try TestFiles.makeFolder()
        try app("Helium", framework: "Helium Framework.framework", in: applications)
        try app("Google Chrome", framework: "Google Chrome Framework.framework", in: applications)
        try app("Arc", framework: "ArcCore.framework", in: applications)
        try app("Dia", framework: "ArcCore.framework", in: userApplications)
        try app("Slack", framework: "Electron Framework.framework", in: applications)
        try app("Microsoft Word", framework: "OutlookRightsFramework.framework", in: applications)
        try app("Notes", framework: nil, in: applications)

        let found = ChromiumBrowsers.scan([applications, userApplications])

        #expect(found.map(\.name) == ["Arc", "Dia", "Google Chrome", "Helium"])
        #expect(found.first { $0.name == "Dia" }?.appURL.deletingLastPathComponent().standardizedFileURL == userApplications.standardizedFileURL)
    }

    @Test func aMissingApplicationsFolderFindsNothing() {
        #expect(ChromiumBrowsers.scan([URL(filePath: "/nonexistent-\(UUID())")]).isEmpty)
    }
}

struct BrowserListTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aBrowserThatIsConnectingBeatsOneThatIsAway() {
        let helium = InstalledBrowser(name: "Helium", appURL: URL(filePath: "/Applications/Helium.app"))
        let away = BrowserLink(id: UUID(), name: "Helium", state: .notConnected)
        let connecting = BrowserLink(id: UUID(), name: "Helium", state: .connecting)

        #expect(BrowserList.rows(installed: [helium], links: [away, connecting]).first?.state == .connecting)
    }

    @Test func aBrowserPairedTwiceShowsItsConnectedPairingFirstThenOneNeedingReload() {
        let helium = InstalledBrowser(name: "Helium", appURL: URL(filePath: "/Applications/Helium.app"))
        let stale = BrowserLink(id: UUID(), name: "Helium", state: .notConnected)
        let old = BrowserLink(id: UUID(), name: "Helium", state: .needsReload)
        let live = BrowserLink(id: UUID(), name: "Helium", state: .connected)

        #expect(BrowserList.rows(installed: [helium], links: [stale, old, live]).first?.link == live)
        #expect(BrowserList.rows(installed: [helium], links: [stale, old]).first?.link == old)
    }

    @Test func eachInstalledBrowserShowsWhetherDowlioConnectIsThereAndAPairedOneTheScanMissedStillShows() {
        let arc = InstalledBrowser(name: "Arc", appURL: URL(filePath: "/Applications/Arc.app"))
        let helium = InstalledBrowser(name: "Helium", appURL: URL(filePath: "/Applications/Helium.app"))
        let brave = InstalledBrowser(name: "Brave Browser", appURL: URL(filePath: "/Applications/Brave Browser.app"))
        let links = [
            BrowserLink(id: UUID(), name: "Arc", state: .connected),
            BrowserLink(id: UUID(), name: "Helium", state: .notConnected),
            BrowserLink(id: UUID(), name: "Thorium", state: .notConnected),
        ]

        let rows = BrowserList.rows(installed: [arc, helium, brave], links: links)

        #expect(rows.map(\.name) == ["Arc", "Brave Browser", "Helium", "Thorium"])
        #expect(rows.map(\.state) == [.connected, .notInstalled, .notConnected, .notConnected])
        #expect(rows.first { $0.name == "Thorium" }?.appURL == nil)
        #expect(rows.first { $0.name == "Arc" }?.link?.name == "Arc")
    }
}

final class FakeConnectExtension: @unchecked Sendable {
    let client: ConnectClient
    private let answers: Bool
    private var task: Task<Void, Never>?

    init(_ client: ConnectClient, answersPings: Bool) {
        self.client = client
        answers = answersPings
        task = Task { [client, answers] in
            while let message = try? await client.receive(timeout: .seconds(10)) {
                guard answers, message["type"] as? String == "ping" else { continue }
                try? await client.send(["v": 1, "type": "pong", "requestId": message["requestId"] as? String ?? ""])
            }
        }
    }

    deinit { task?.cancel() }
}

@Suite(.timeLimit(.minutes(1)))
struct BrowserLinkTests {
    @Test func aBrowserIsConnectedForAMinuteAfterItIsLastHeardFrom() async throws {
        let clock = TestClock()
        let fixture = try await ConnectFixture(now: clock.now)
        _ = try await fixture.helloClient()

        let fresh = await fixture.server.browserLinks()
        clock.advance(by: 61)
        let stale = await fixture.server.browserLinks()

        #expect(fresh.map(\.state) == [.connected])
        #expect(fresh.map(\.name) == ["Arc"])
        #expect(stale.map(\.state) == [.notConnected])
    }

    @Test func aBrowserJustAllowedShowsConnectingUntilItSaysHello() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()

        let allowed = await fixture.server.browserLinks().map(\.state)
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()

        #expect(allowed == [.connecting])
        #expect(await fixture.server.browserLinks().map(\.state) == [.connected])
    }

    @Test func aBrowserThatNeverSaysHelloStopsConnectingAfterTwentySeconds() async throws {
        let clock = TestClock()
        let fixture = try await ConnectFixture(now: clock.now)
        _ = try await fixture.pairedToken()

        clock.advance(by: 19)
        let waiting = await fixture.server.browserLinks().map(\.state)
        clock.advance(by: 2)

        #expect(waiting == [.connecting])
        #expect(await fixture.server.browserLinks().map(\.state) == [.notConnected])
    }

    @Test func theBrowserListIsToldWhenAPairingOrAConnectionChanges() async throws {
        let fixture = try await ConnectFixture()
        var changes = fixture.server.browserChanges.makeAsyncIterator()

        let token = try await fixture.pairedToken()
        _ = await changes.next()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = await changes.next()
        client.close()
        _ = await changes.next()
    }

    @Test func aBrowserThatClosesItsConnectionIsNotConnectedAtOnce() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        client.close()
        try await Task.sleep(for: .milliseconds(200))

        #expect(await fixture.server.browserLinks().map(\.state) == [.notConnected])
    }

    @Test func testPassesWhenDowlioConnectAnswersAPing() async throws {
        let fixture = try await ConnectFixture()
        let browser = FakeConnectExtension(try await fixture.helloClient(), answersPings: true)
        let link = try #require(await fixture.server.browserLinks().first)

        #expect(await fixture.server.test(link.id) == .passed)
        _ = browser
    }

    @Test func testSaysDowlioConnectDidntAnswerWhenThePingGoesUnanswered() async throws {
        let fixture = try await ConnectFixture(testTimeout: .milliseconds(300))
        let browser = FakeConnectExtension(try await fixture.helloClient(), answersPings: false)
        let link = try #require(await fixture.server.browserLinks().first)

        #expect(await fixture.server.test(link.id) == .noAnswer)
        _ = browser
    }

    @Test func aBrowserThatLeavesDuringTestIsReportedAsNotConnected() async throws {
        let fixture = try await ConnectFixture(testTimeout: .seconds(5))
        let client = try await fixture.helloClient()
        let link = try #require(await fixture.server.browserLinks().first)

        async let result = fixture.server.test(link.id)
        try await Task.sleep(for: .milliseconds(100))
        client.close()

        #expect(await result == .notConnected)
    }

    @Test func testSaysNoDowlioConnectIsConnectedWhenThatBrowserIsAway() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()
        let link = try #require(await fixture.server.browserLinks().first)
        client.close()
        try await Task.sleep(for: .milliseconds(200))

        #expect(await fixture.server.test(link.id) == .notConnected)
    }

    @Test func testSaysThePairingIsMissingForABrowserDowlioDoesntKnow() async throws {
        let fixture = try await ConnectFixture()
        #expect(await fixture.server.test(UUID()) == .pairingMissing)
    }

    @Test func testSaysTheServerIsntListeningBeforeItStarts() async throws {
        let store = try DownloadStore(databaseAt: TestFiles.makeFolder().appending(path: "Dowlio.sqlite"))
        let server = ConnectServer(ports: ConnectFixture.freePorts(), store: store, vault: MemoryTokenVault()) { _ in true }
        #expect(await server.test(UUID()) == .serverNotListening)
    }

    @Test func testSaysAnotherAppHasThePortWhenDowlioCouldntListen() async throws {
        let fixture = try await ConnectFixture()
        let store = try DownloadStore(databaseAt: TestFiles.makeFolder().appending(path: "Dowlio.sqlite"))
        let second = ConnectServer(ports: [fixture.port], store: store, vault: MemoryTokenVault()) { _ in true }

        await #expect(throws: ConnectServerError.noFreePort) { try await second.start() }
        #expect(await second.test(UUID()) == .portInUse)
    }

    @Test func aNewPairingIsNamedByDowlioRatherThanByTheExtensionsBrand() async throws {
        let approvals = Approvals()
        let fixture = try await ConnectFixture(approvals: approvals, nameBrowser: { reported in reported == "Google Chrome" ? "Helium" : reported })

        _ = try await fixture.pairedToken(browser: "Google Chrome")

        #expect(approvals.received.map(\.browser) == ["Helium"])
        #expect(try fixture.store.browserPairings().map(\.browserName) == ["Helium"])
    }
}

struct ExtensionFolderTests {
    @Test func installingCopiesDowlioConnectAndReplacesWhatWasThereBefore() throws {
        let bundled = try TestFiles.makeFolder()
        try Data("{\"version\":\"0.2.1\"}".utf8).write(to: bundled.appending(path: "manifest.json"))
        try FileManager.default.createDirectory(at: bundled.appending(path: "lib"), withIntermediateDirectories: true)
        try Data("export {}".utf8).write(to: bundled.appending(path: "lib/worker.js"))
        let destination = try TestFiles.makeFolder().appending(path: "Browser Extension", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "stale.js"))

        try ExtensionFolder.install(from: bundled, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "lib/worker.js").path))
        #expect(try String(contentsOf: destination.appending(path: "manifest.json"), encoding: .utf8).contains("0.2.1"))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "stale.js").path))
    }
}

struct LinkTestTextTests {
    @Test(arguments: [
        (LinkTestResult.passed, "Dowlio Connect answered. Arc is connected."),
        (.serverNotListening, "Dowlio isn't listening for browsers. Quit Dowlio and open it again."),
        (.portInUse, "Another app is using Dowlio's ports, 51517 to 51520. Quit that app, then open Dowlio again."),
        (.notConnected, "Dowlio Connect in Arc isn't connected. Open Arc, and it connects within 30 seconds."),
        (.pairingMissing, "Arc isn't paired. Click the Dowlio Connect button in Arc to pair it again."),
        (.noAnswer, "Dowlio Connect in Arc didn't answer within 2 seconds. Open Arc, then test again."),
    ])
    func eachTestResultNamesTheStepInPlainWords(result: LinkTestResult, text: String) {
        #expect(result.text(browser: "Arc") == text)
    }
}
