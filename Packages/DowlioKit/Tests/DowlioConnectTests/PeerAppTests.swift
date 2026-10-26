import DowlioConnect
import Darwin
import Foundation
import Network
import Testing

struct PeerAppNameTests {
    @Test(arguments: [
        ("/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Versions/1/Helpers/Dia Helper.app/Contents/MacOS/Dia Helper", "Dia"),
        ("/Applications/Helium.app/Contents/Frameworks/Helium Framework.framework/Versions/1/Helpers/Helium Helper.app/Contents/MacOS/Helium Helper", "Helium"),
        ("/Applications/Arc.app/Contents/MacOS/Arc", "Arc"),
        ("/Users/me/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", "Brave Browser"),
    ])
    func aBrowsersHelperProcessIsNamedAfterTheAppThatContainsIt(path: String, name: String) {
        #expect(PeerProcess.appName(forExecutable: path) == name)
    }

    @Test(arguments: ["/usr/bin/python3", "/opt/homebrew/bin/node", ""])
    func aProcessOutsideAnAppHasNoAppName(path: String) {
        #expect(PeerProcess.appName(forExecutable: path) == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PeerAppTests {
    @Test func theProcessAtTheOtherEndOfAConnectionIsFound() async throws {
        let seen = Pids()
        let fixture = try await ConnectFixture(peerApp: { connection in
            seen.add(PeerProcess.pid(of: connection))
            return "Dia"
        })

        _ = try await fixture.helloClient()

        #expect(seen.values.contains(getpid()))
    }

    @Test func aBrowserIsNamedAfterItsAppAndNotAfterWhatTheExtensionReports() async throws {
        let approvals = Approvals()
        let fixture = try await ConnectFixture(approvals: approvals, peerApp: { _ in "Dia" })

        _ = try await fixture.pairedToken(browser: "Chromium")

        #expect(approvals.received.map(\.browser) == ["Dia"])
        #expect(try fixture.store.browserPairings().map(\.browserName) == ["Dia"])
    }

    @Test func aBrowserPairedUnderTheEnginesNameIsRenamedWhenItSaysHello() async throws {
        let name = Names(first: "Chromium")
        let fixture = try await ConnectFixture(peerApp: { _ in name.current })
        let token = try await fixture.pairedToken(browser: "Chromium")
        name.current = "Dia"

        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()

        #expect(try fixture.store.browserPairings().map(\.browserName) == ["Dia"])
    }

    @Test func aSentLinkIsLabelledWithTheAppNotTheEnginesBrand() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Dia" })
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/a.pdf", "browser": "Chromium"])
        _ = try await client.receive()

        #expect(try await fixture.nextSentLink().browser == "Dia")
    }

    @Test func withNoAppFoundTheExtensionsOwnNameIsUsed() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in nil })
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/a.pdf", "browser": "Arc"])
        _ = try await client.receive()

        #expect(try await fixture.nextSentLink().browser == "Arc")
    }
}

final class Pids: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [pid_t] = []
    func add(_ pid: pid_t?) { if let pid { lock.withLock { all.append(pid) } } }
    var values: [pid_t] { lock.withLock { all } }
}

final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String
    init(first: String) { name = first }
    var current: String {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}
