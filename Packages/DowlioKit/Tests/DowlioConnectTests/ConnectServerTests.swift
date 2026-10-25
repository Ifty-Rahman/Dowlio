import DowlioConnect
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ConnectServerTests {
    @Test func aWebPageCannotConnect() async throws {
        let fixture = try await ConnectFixture()

        await #expect(throws: ConnectClientError.closed) {
            _ = try await fixture.client(origin: "https://evil.example")
        }
        await #expect(throws: ConnectClientError.closed) {
            _ = try await fixture.client(origin: nil)
        }
        _ = try await fixture.client()
    }

    @Test func anApprovedPairingGivesTheExtensionATokenAndKeepsOnlyItsHash() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "pair.request", "requestId": "r1", "code": "4821", "browser": "Arc", "version": "0.2.0", "extensionId": "abcdefghijklmnopabcdefghijklmnop"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pair.approved")
        #expect(reply["requestId"] as? String == "r1")
        let token = try #require(reply["token"] as? String)
        #expect(Data(base64URLEncoded: token)?.count == 32)
        #expect(fixture.approvals.received == [PairingRequest(code: "4821", browser: "Arc", extensionVersion: "0.2.0")])
        #expect(fixture.vault.storedHashes.count == 1)
        #expect(!fixture.vault.storedHashes.contains(Data(token.utf8)))
        let pairing = try #require(try fixture.store.browserPairings().first)
        #expect(pairing.browserName == "Arc")
        #expect(pairing.extensionID == "abcdefghijklmnopabcdefghijklmnop")
        #expect(pairing.extensionVersion == "0.2.0")
    }

    @Test func aPairedExtensionIsRecognisedOnALaterConnection() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "requestId": "h1", "token": token, "version": "0.2.1"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "hello.ok")
        #expect(reply["requestId"] as? String == "h1")
        #expect(try fixture.store.browserPairings().first?.extensionVersion == "0.2.1")
    }

    @Test func aHelloWithAnUnknownTokenIsRejectedAndClosed() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "token": "not-a-token", "version": "0.2.0"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "hello.rejected")
        #expect(await client.waitUntilClosed())
    }

    @Test func anUnpairedConnectionThatSendsAnythingButPairingHelloOrPingIsClosed() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "catch.offer", "url": "https://example.com/file.zip"])

        #expect(await client.waitUntilClosed())
    }

    @Test func anUnpairedConnectionCanPingToStayAliveWhileThePairingAlertWaits() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "ping", "requestId": "p0"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pong")
        #expect(try fixture.store.browserPairings().isEmpty)
    }

    @Test func aMalformedFirstMessageClosesTheConnection() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.sendRaw(Data("{not json".utf8))

        #expect(await client.waitUntilClosed())
    }

    @Test func aPingAfterHelloGetsAPongAndMarksTheBrowserSeen() async throws {
        let clock = TestClock()
        let fixture = try await ConnectFixture(now: clock.now)
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()
        _ = try await client.receive()
        clock.advance(by: 90)

        try await client.send(["v": 1, "type": "ping", "requestId": "p1"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pong")
        #expect(reply["requestId"] as? String == "p1")
        #expect(try fixture.store.browserPairings().first?.lastSeenAt == clock.now())
    }

    @Test func anUnknownOrMalformedMessageAfterHelloGetsAnErrorAndTheLinkStaysUp() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()
        _ = try await client.receive()

        try await client.send(["v": 1, "type": "teleport", "requestId": "u1"])
        let unknown = try await client.receive()
        try await client.sendRaw(Data("{not json".utf8))
        let malformed = try await client.receive()
        try await client.send(["v": 99, "type": "ping"])
        let futureVersion = try await client.receive()
        try await client.send(["v": 1, "type": "ping"])
        let pong = try await client.receive()

        #expect(unknown["type"] as? String == "error")
        #expect(unknown["reason"] as? String == "unknownType")
        #expect(unknown["requestId"] as? String == "u1")
        #expect(malformed["reason"] as? String == "invalidMessage")
        #expect(futureVersion["reason"] as? String == "invalidMessage")
        #expect(pong["type"] as? String == "pong")
    }

    @Test func aMessageOver256KBClosesTheConnection() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()
        _ = try await client.receive()

        try await client.send(["v": 1, "type": "ping", "padding": String(repeating: "x", count: 300 * 1024)])

        #expect(await client.waitUntilClosed())
    }

    @Test func aDeniedPairingGivesNoToken() async throws {
        let fixture = try await ConnectFixture(approvals: Approvals { _ in false })
        let client = try await fixture.client()

        try await client.send(Self.pairRequest(code: "1234"))
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pair.refused")
        #expect(reply["reason"] as? String == "denied")
        #expect(reply["token"] == nil)
        #expect(try fixture.store.browserPairings().isEmpty)
    }

    @Test func onlyOnePairingRequestIsShownAtATime() async throws {
        let gate = Gate()
        let fixture = try await ConnectFixture(approvals: Approvals { _ in await gate.wait() })
        let first = try await fixture.client()
        let second = try await fixture.client()

        try await first.send(Self.pairRequest(code: "1111"))
        try await fixture.approvals.waitForRequests(1)
        try await second.send(Self.pairRequest(code: "2222"))
        let busy = try await second.receive()
        await gate.open(with: true)
        let approved = try await first.receive()

        #expect(busy["reason"] as? String == "busy")
        #expect(approved["type"] as? String == "pair.approved")
        #expect(fixture.approvals.received.map(\.code) == ["1111"])
    }

    @Test func allowingAPairingAfterItsBrowserHasGoneCreatesNoPairing() async throws {
        let gate = Gate()
        let fixture = try await ConnectFixture(approvals: Approvals { _ in await gate.wait() })
        let client = try await fixture.client()
        try await client.send(Self.pairRequest(code: "3333"))
        try await fixture.approvals.waitForRequests(1)

        client.close()
        try await Task.sleep(for: .milliseconds(100))
        await gate.open(with: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(try fixture.store.browserPairings().isEmpty)
        #expect(fixture.vault.storedHashes.isEmpty)
    }

    @Test func moreThanFivePairingRequestsAMinuteAreRefusedWithoutAsking() async throws {
        let clock = TestClock()
        let fixture = try await ConnectFixture(approvals: Approvals { _ in false }, now: clock.now)
        let client = try await fixture.client()

        var reasons: [String] = []
        for index in 0..<6 {
            try await client.send(Self.pairRequest(code: "100\(index)"))
            reasons.append(try await client.receive()["reason"] as? String ?? "")
        }
        clock.advance(by: 61)
        try await client.send(Self.pairRequest(code: "2000"))
        let afterAMinute = try await client.receive()

        #expect(reasons == ["denied", "denied", "denied", "denied", "denied", "tooManyRequests"])
        #expect(afterAMinute["reason"] as? String == "denied")
        #expect(fixture.approvals.received.count == 6)
    }

    @Test func theServerMovesToTheNextPortWhenTheFirstIsTaken() async throws {
        let ports = ConnectFixture.freePorts()
        let blocker = try await ConnectFixture(ports: [ports[0]])

        let fixture = try await ConnectFixture(ports: ports)

        #expect(blocker.port == ports[0])
        #expect(fixture.port == ports[1])
    }

    static func pairRequest(code: String) -> [String: Any] {
        ["v": 1, "type": "pair.request", "code": code, "browser": "Arc", "version": "0.2.0", "extensionId": "abcdefghijklmnopabcdefghijklmnop"]
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
