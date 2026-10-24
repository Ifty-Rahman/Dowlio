import DowlioConnect
import DowlioStore
import DowlioTestSupport
import Foundation

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

    init(approvals: Approvals = Approvals(), ports: [UInt16]? = nil, now: @escaping @Sendable () -> Date = Date.init) async throws {
        let base = try TestFiles.makeFolder()
        store = try DownloadStore(databaseAt: base.appending(path: "Dowlio.sqlite"))
        vault = MemoryTokenVault()
        self.approvals = approvals
        server = ConnectServer(ports: ports ?? Self.freePorts(), store: store, vault: vault, now: now) { request in
            await approvals.decide(request)
        }
        port = try await server.start()
    }

    func client(origin: String? = ConnectClient.extensionOrigin) async throws -> ConnectClient {
        try await ConnectClient.connect(port: port, origin: origin)
    }

    func pairedToken(browser: String = "Arc") async throws -> String {
        let client = try await client()
        try await client.send(["v": 1, "type": "pair.request", "code": "4821", "browser": browser, "version": "0.2.0", "extensionId": "abcdefghijklmnopabcdefghijklmnop"])
        let reply = try await client.receive()
        client.close()
        return reply["token"] as? String ?? ""
    }

    static func freePorts(count: Int = 4) -> [UInt16] {
        let start = UInt16.random(in: 40000...60000)
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
