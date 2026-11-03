import CryptoKit
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

    @Test func typingTheCodeDowlioShowsGivesTheExtensionATokenAndKeepsOnlyItsHash() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        let reply = try await fixture.pair(client, requestID: "r1")

        #expect(reply["type"] as? String == "pair.approved")
        let token = try #require(reply["token"] as? String)
        #expect(Data(base64URLEncoded: token)?.count == 32)
        let request = try #require(fixture.approvals.received.first)
        #expect(request.code.count == 6 && request.code.allSatisfy(\.isNumber))
        #expect(request.browser == "Arc")
        #expect(!request.isIdentified)
        #expect(fixture.vault.storedHashes.count == 1)
        #expect(!fixture.vault.storedHashes.contains(Data(token.utf8)))
        let pairing = try #require(try fixture.store.browserPairings().first)
        #expect(pairing.browserName == "Arc")
        #expect(pairing.extensionID == "abcdefghijklmnopabcdefghijklmnop")
        #expect(pairing.extensionVersion == "0.2.0")
    }

    @Test func aWrongCodeLeavesTriesThenTheThirdEndsTheRequest() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()
        try await client.send(Self.pairRequest())
        _ = try await client.receive()
        try await fixture.approvals.waitForRequests(1)
        let wrong = fixture.approvals.received[0].code == "000000" ? "111111" : "000000"

        var replies: [[String: Any]] = []
        for _ in 0..<3 {
            try await client.send(["v": 1, "type": "pair.code", "code": wrong])
            replies.append(try await client.receive())
        }

        #expect(replies.map { $0["type"] as? String } == ["pair.codeWrong", "pair.codeWrong", "pair.refused"])
        #expect(replies.map { $0["left"] as? Int } == [2, 1, nil])
        #expect(try fixture.store.browserPairings().isEmpty)
    }

    @Test func aPairedExtensionProvesItselfOnALaterConnectionWithoutSendingItsToken() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await fixture.sayHello(on: client, token: token, version: "0.2.1", requestID: "h1")
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "hello.ok")
        #expect(try fixture.store.browserPairings().first?.extensionVersion == "0.2.1")
    }

    @Test func theChallengeProvesDowlioKnowsTheSecret() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        let secret = Data(SHA256.hash(data: Data(token.utf8)))

        try await client.send(["v": 1, "type": "hello", "key": Proof.code(secret, "dowlio-connect key"), "nonce": "client-nonce-0123456789abcdef", "version": "0.2.0"])
        let challenge = try await client.receive()

        let server = try #require(challenge["nonce"] as? String)
        #expect(challenge["proof"] as? String == Proof.code(secret, "dowlio-connect server client-nonce-0123456789abcdef \(server)"))
    }

    @Test func aWrongProofIsRejectedAndClosed() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        let secret = Data(SHA256.hash(data: Data(token.utf8)))
        try await client.send(["v": 1, "type": "hello", "key": Proof.code(secret, "dowlio-connect key"), "nonce": "client-nonce-0123456789abcdef", "version": "0.2.0"])
        _ = try await client.receive()

        try await client.send(["v": 1, "type": "hello.proof", "proof": "a-guess-that-is-not-the-proof"])

        #expect(try await client.receive()["type"] as? String == "hello.rejected")
        #expect(await client.waitUntilClosed())
    }

    @Test func aHelloWithAnUnknownKeyIsRejectedAndClosed() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "key": "an-unknown-key-0123456789", "nonce": "client-nonce-0123456789abcdef", "version": "0.2.0"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "hello.rejected")
        #expect(await client.waitUntilClosed())
    }

    @Test func anOldExtensionSendingItsTokenIsOnlyToldToReload() async throws {
        let fixture = try await ConnectFixture()
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.3.18"])

        #expect(try await client.receive()["type"] as? String == "extension.reload")
        #expect(await client.waitUntilClosed())
        #expect(await fixture.server.browserLinks().allSatisfy { $0.state != .connected })
    }

    @Test func onlyDowlioConnectsOwnExtensionCanConnectOrPair() async throws {
        let fixture = try await ConnectFixture(extensionIDs: { ["abcdefghijklmnopabcdefghijklmnop"] })

        await #expect(throws: ConnectClientError.closed) {
            _ = try await fixture.client(origin: "chrome-extension://pppppppppppppppppppppppppppppppp")
        }
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "pair.request", "browser": "Arc", "version": "0.2.0", "extensionId": "pppppppppppppppppppppppppppppppp"])
        #expect(try await client.receive()["reason"] as? String == "denied")
        #expect(fixture.approvals.received.isEmpty)
    }

    @Test func aSilentUnpairedConnectionIsClosed() async throws {
        let fixture = try await ConnectFixture(silentTimeout: .milliseconds(200))
        let client = try await fixture.client()

        #expect(await client.waitUntilClosed(timeout: .seconds(2)))
    }

    @Test func noMoreThanSixteenConnectionsStayOpen() async throws {
        let fixture = try await ConnectFixture()
        var clients: [ConnectClient] = []
        for _ in 0..<16 { clients.append(try await fixture.client()) }

        let extra = try? await fixture.client()
        let closed = await extra?.waitUntilClosed(timeout: .seconds(1)) ?? true

        #expect(closed)
    }

    static let messagesThatNeedPairing: [[String: any Sendable]] = [
        ["v": 1, "type": "catch.offer", "url": "http://127.0.0.1:9/file.zip", "cookies": [] as [String]],
        ["v": 1, "type": "catch.released", "requestId": "c1"],
        ["v": 1, "type": "link.send", "url": "http://127.0.0.1:9/file.zip", "cookies": [] as [String]],
        ["v": 1, "type": "settings.change", "catches": false],
        ["v": 1, "type": "pong", "requestId": "p1"],
        ["v": 1, "type": "something.new"],
    ]

    @Test(arguments: messagesThatNeedPairing)
    func anUnpairedConnectionThatSendsAnythingButPairingHelloOrPingIsClosed(_ message: [String: any Sendable]) async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(message)

        #expect(await client.waitUntilClosed())
        #expect(try fixture.store.browserPairings().isEmpty)
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test(arguments: messagesThatNeedPairing)
    func aPairedConnectionCanSendEachMessageThatNeedsPairing(_ message: [String: any Sendable]) async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send(message)
        try await client.send(["v": 1, "type": "ping", "requestId": "after"])

        var replies: [[String: Any]] = []
        while true {
            let reply = try await client.receive()
            if reply["requestId"] as? String == "after", reply["type"] as? String == "pong" { break }
            replies.append(reply)
        }
        #expect(!replies.contains { $0["type"] as? String == "error" && $0["reason"] as? String == "invalidMessage" })
    }

    @Test func anUnpairedConnectionCanPingToStayAliveWhileThePairingAlertWaits() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "ping", "requestId": "p0"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pong")
        #expect(try fixture.store.browserPairings().isEmpty)
        try await client.send(["v": 1, "type": "catch.offer", "url": "http://127.0.0.1:9/file.zip", "cookies": [] as [String]])
        #expect(await client.waitUntilClosed())
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
        try await fixture.sayHello(on: client, token: token, version: "0.2.0")
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
        try await fixture.sayHello(on: client, token: token, version: "0.2.0")
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
        try await fixture.sayHello(on: client, token: token, version: "0.2.0")
        _ = try await client.receive()
        _ = try await client.receive()

        try await client.send(["v": 1, "type": "ping", "padding": String(repeating: "x", count: 300 * 1024)])

        #expect(await client.waitUntilClosed())
    }

    @Test func dontAllowGivesNoToken() async throws {
        let fixture = try await ConnectFixture(approvals: Approvals { _ in false })
        let client = try await fixture.client()

        try await client.send(Self.pairRequest())
        _ = try await client.receive()
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "pair.refused")
        #expect(reply["reason"] as? String == "denied")
        #expect(reply["token"] == nil)
        #expect(try fixture.store.browserPairings().isEmpty)
    }

    @Test func onlyOnePairingRequestIsShownAtATime() async throws {
        let fixture = try await ConnectFixture()
        let first = try await fixture.client()
        let second = try await fixture.client()

        try await first.send(Self.pairRequest())
        _ = try await first.receive()
        try await fixture.approvals.waitForRequests(1)
        try await second.send(Self.pairRequest())
        let busy = try await second.receive()
        try await first.send(["v": 1, "type": "pair.code", "code": fixture.approvals.received[0].code])
        let approved = try await first.receive()

        #expect(busy["reason"] as? String == "busy")
        #expect(approved["type"] as? String == "pair.approved")
        #expect(fixture.approvals.received.count == 1)
    }

    @Test func aCodeSentAfterItsBrowserHasGoneCreatesNoPairing() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()
        try await client.send(Self.pairRequest())
        _ = try await client.receive()
        try await fixture.approvals.waitForRequests(1)

        client.close()
        try await Task.sleep(for: .milliseconds(100))
        let next = try await fixture.client()
        try await next.send(["v": 1, "type": "pair.code", "code": fixture.approvals.received[0].code])

        #expect(await next.waitUntilClosed())
        #expect(try fixture.store.browserPairings().isEmpty)
        #expect(fixture.vault.storedHashes.isEmpty)
    }

    @Test func moreThanFivePairingRequestsAMinuteAreRefusedWithoutAsking() async throws {
        let clock = TestClock()
        let fixture = try await ConnectFixture(approvals: Approvals { _ in false }, now: clock.now)
        let client = try await fixture.client()

        var reasons: [String] = []
        for _ in 0..<6 {
            try await client.send(Self.pairRequest())
            let first = try await client.receive()
            reasons.append(first["type"] as? String == "pair.codeNeeded" ? try await client.receive()["reason"] as? String ?? "" : first["reason"] as? String ?? "")
        }
        clock.advance(by: 61)
        try await client.send(Self.pairRequest())
        let afterAMinute = try await client.receive()

        #expect(reasons == ["denied", "denied", "denied", "denied", "denied", "tooManyRequests"])
        #expect(afterAMinute["type"] as? String == "pair.codeNeeded")
        #expect(fixture.approvals.received.count == 6)
    }

    @Test func theServerMovesToTheNextPortWhenTheFirstIsTaken() async throws {
        let ports = ConnectFixture.freePorts()
        let blocker = try await ConnectFixture(ports: [ports[0]])

        let fixture = try await ConnectFixture(ports: ports)

        #expect(blocker.port == ports[0])
        #expect(fixture.port == ports[1])
    }

    static func pairRequest() -> [String: Any] {
        ["v": 1, "type": "pair.request", "browser": "Arc", "version": "0.2.0", "extensionId": "abcdefghijklmnopabcdefghijklmnop"]
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
