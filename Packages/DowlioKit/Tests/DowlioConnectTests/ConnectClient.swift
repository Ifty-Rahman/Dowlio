import Foundation
import Network

enum ConnectClientError: Error {
    case closed
    case timedOut
}

final class ConnectClient: @unchecked Sendable {
    static let extensionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ConnectClient")
    private var inbox: [Data] = []
    private var waiters: [Waiter] = []
    private var isClosed = false
    private var readyWaiter: CheckedContinuation<Void, Error>?

    init(port: UInt16, origin: String? = ConnectClient.extensionOrigin) {
        let options = NWProtocolWebSocket.Options()
        options.maximumMessageSize = 4 * 1024 * 1024
        if let origin { options.setAdditionalHeaders([("Origin", origin)]) }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: parameters)
    }

    static func connect(port: UInt16, origin: String? = ConnectClient.extensionOrigin) async throws -> ConnectClient {
        let client = ConnectClient(port: port, origin: origin)
        try await client.start()
        return client
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                readyWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                connection.start(queue: queue)
            }
        }
        receiveNext()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyWaiter?.resume()
            readyWaiter = nil
        case .failed, .cancelled:
            readyWaiter?.resume(throwing: ConnectClientError.closed)
            readyWaiter = nil
            markClosed()
        case .waiting:
            readyWaiter?.resume(throwing: ConnectClientError.closed)
            readyWaiter = nil
            connection.cancel()
        default:
            break
        }
    }

    private func markClosed() {
        isClosed = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(throwing: ConnectClientError.closed) }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                markClosed()
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                if waiters.isEmpty { inbox.append(data) } else { waiters.removeFirst().continuation.resume(returning: data) }
            }
            receiveNext()
        }
    }

    func send(_ object: [String: Any]) async throws {
        try await sendRaw(JSONSerialization.data(withJSONObject: object))
    }

    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive(timeout: Duration = .seconds(3)) async throws -> [String: Any] {
        let data = try await receiveData(timeout: timeout)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func receiveData(timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                    return
                }
                if isClosed {
                    continuation.resume(throwing: ConnectClientError.closed)
                    return
                }
                let waiter = Waiter(continuation)
                waiters.append(waiter)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { [self] in
                    guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return }
                    waiters.remove(at: index)
                    waiter.continuation.resume(throwing: ConnectClientError.timedOut)
                }
            }
        }
    }

    func waitUntilClosed(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if queue.sync(execute: { isClosed }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func close() {
        connection.cancel()
    }
}

private final class Waiter {
    let continuation: CheckedContinuation<Data, Error>

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }
}
