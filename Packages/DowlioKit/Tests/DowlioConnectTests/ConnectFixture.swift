import CryptoKit
import DowlioConnect
import DowlioCore
import DowlioMedia
import DowlioEngine
import DowlioLibrary
import DowlioStore
import DowlioTestSupport
import Foundation
import Network

final class Approvals: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PairingRequest] = []
    private var answer: @Sendable (PairingRequest) async -> Bool

    init(answer: @escaping @Sendable (PairingRequest) async -> Bool = { _ in true }) {
        self.answer = answer
    }

    var received: [PairingRequest] { lock.withLock { requests } }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 where received.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func decide(_ request: PairingRequest) async -> Bool {
        lock.withLock { requests.append(request) }
        return await answer(request)
    }
}

struct ConnectFixture {
    let server: ConnectServer
    let port: UInt16
    let store: DownloadStore
    let vault: MemoryTokenVault
    let approvals: Approvals

    let library: Library
    let base: URL
    let dowlioFolder: URL

    init(
        approvals: Approvals = Approvals(),
        ports: [UInt16]? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        settings: (@Sendable (URL) -> DownloadSettings)? = nil,
        catchDeadline: Duration = .seconds(4),
        releaseWait: Duration = .milliseconds(100),
        preferences: CatchPreferences = CatchPreferences(),
        testTimeout: Duration = .seconds(2),
        scanTimeout: Duration = .seconds(8),
        signInTimeout: Duration = .seconds(1),
        nameBrowser: @escaping @Sendable (String) -> String = { $0 },
        extensionVersion: String? = nil,
        peerApp: @escaping @Sendable (NWConnection) -> String? = { _ in nil },
        extensionIDs: @escaping @Sendable () -> Set<String>? = { nil },
        silentTimeout: Duration = .seconds(10)
    ) async throws {
        base = try TestFiles.makeFolder()
        dowlioFolder = base.appending(path: "Dowlio Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dowlioFolder, withIntermediateDirectories: true)
        store = try DownloadStore(databaseAt: base.appending(path: "Dowlio.sqlite"))
        library = Library(engine: DownloadEngine(configuration: .fast), store: store)
        await library.start()
        vault = MemoryTokenVault()
        self.approvals = approvals
        let folder = dowlioFolder
        let chosenSettings: @Sendable () -> DownloadSettings = { settings?(folder) ?? DownloadSettings(folder: folder) }
        let catcher = Catcher(library: library, settings: chosenSettings)
        server = ConnectServer(
            ports: ports ?? [0], store: store, vault: vault, now: now, catcher: catcher, catchDeadline: catchDeadline, releaseWait: releaseWait, preferences: preferences,
            testTimeout: testTimeout, scanTimeout: scanTimeout, signInTimeout: signInTimeout, nameBrowser: nameBrowser, extensionVersion: extensionVersion, peerApp: peerApp,
            extensionIDs: extensionIDs, silentTimeout: silentTimeout
        ) { request in
            await approvals.decide(request)
        }
        port = try await server.start()
    }

    func helloClient() async throws -> ConnectClient {
        let token = try await pairedToken()
        let client = try await client()
        try await sayHello(on: client, token: token)
        _ = try await client.receive()
        _ = try await client.receive()
        return client
    }

    func sayHello(on client: ConnectClient, token: String, version: String = "0.2.0", requestID: String? = nil) async throws {
        let secret = Data(SHA256.hash(data: Data(token.utf8)))
        let nonce = "client-nonce-0123456789abcdef"
        var hello: [String: Any] = ["v": 1, "type": "hello", "key": Proof.code(secret, "dowlio-connect key"), "nonce": nonce, "version": version]
        if let requestID { hello["requestId"] = requestID }
        try await client.send(hello)
        let challenge = try await client.receive()
        guard challenge["type"] as? String == "hello.challenge", let server = challenge["nonce"] as? String else { return }
        try await client.send(["v": 1, "type": "hello.proof", "proof": Proof.code(secret, "dowlio-connect client \(nonce) \(server)")])
    }

    func nextPreferenceChange() async throws -> CatchPreferenceChange {
        for await change in server.preferenceChanges { return change }
        throw ConnectClientError.closed
    }

    func nextSentLink() async throws -> SentLink {
        for await link in server.sentLinks { return link }
        throw ConnectClientError.closed
    }
    func nextSentPage() async throws -> SentPage {
        for await page in server.sentPages { return page }
        throw ConnectClientError.closed
    }

    func nextCatch() async throws -> CaughtDownload {
        for await caught in server.catches { return caught }
        throw ConnectClientError.closed
    }

    func rowsNow() async -> [DownloadRow] {
        for await rows in await library.rows() { return rows }
        return []
    }

    func firstRow(where condition: @escaping @Sendable (DownloadRow) -> Bool) async throws -> DownloadRow {
        for await rows in await library.rows() {
            if let row = rows.first(where: condition) { return row }
        }
        throw ConnectClientError.closed
    }

    func client(origin: String? = ConnectClient.extensionOrigin) async throws -> ConnectClient {
        try await ConnectClient.connect(port: port, origin: origin)
    }

    func pairedToken(browser: String = "Arc") async throws -> String {
        let client = try await client()
        let reply = try await pair(client, browser: browser)
        client.close()
        return reply["token"] as? String ?? ""
    }

    func pair(_ client: ConnectClient, browser: String = "Arc", requestID: String? = nil) async throws -> [String: Any] {
        let before = approvals.received.count
        var request: [String: Any] = ["v": 1, "type": "pair.request", "browser": browser, "version": "0.2.0", "extensionId": "abcdefghijklmnopabcdefghijklmnop"]
        if let requestID { request["requestId"] = requestID }
        try await client.send(request)
        let needed = try await client.receive()
        guard needed["type"] as? String == "pair.codeNeeded" else { return needed }
        try await approvals.waitForRequests(before + 1)
        try await client.send(["v": 1, "type": "pair.code", "code": approvals.received[before].code])
        return try await client.receive()
    }

    static func freePorts(count: Int = 4) -> [UInt16] {
        let start = UInt16.random(in: 20000...30000)
        return (0..<UInt16(count)).map { start + $0 }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

actor Gate {
    private var answer: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let answer { return answer }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func open(with answer: Bool) {
        self.answer = answer
        for waiter in waiters { waiter.resume(returning: answer) }
        waiters = []
    }
}

enum Proof {
    static func code(_ secret: Data, _ text: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
