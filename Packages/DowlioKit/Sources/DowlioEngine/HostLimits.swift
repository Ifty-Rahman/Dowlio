import Foundation

/// The connection limits Dowlio learned per host. A host that refused
/// connections gets fewer the next time. The engine keeps them in memory by default. Phase 3
/// persists them behind this protocol.
public protocol HostLimitStore: Sendable {
    /// The most connections to open to `host`, or `nil` while Dowlio hasn't learned a limit.
    func limit(for host: String) -> Int?
    /// Replaces `host`'s limit with what `change` makes of the current one, in one step, so two
    /// connections refused at once both count.
    func updateLimit(for host: String, _ change: (Int?) -> Int)
}

/// Host limits kept in memory for as long as the engine runs.
public final class InMemoryHostLimitStore: HostLimitStore, @unchecked Sendable {
    // @unchecked: `limits` is only read or written under `lock`.
    private let lock = NSLock()
    private var limits: [String: Int] = [:]

    public init() {}

    public func limit(for host: String) -> Int? {
        lock.withLock { limits[host] }
    }

    public func updateLimit(for host: String, _ change: (Int?) -> Int) {
        lock.withLock { limits[host] = change(limits[host]) }
    }
}

extension URL {
    /// The key a host's limit is stored under: the host, with the port when the URL names one.
    var hostLimitKey: String? {
        guard let host = host?.lowercased() else { return nil }
        return port.map { "\(host):\($0)" } ?? host
    }
}

/// How many of a download's connections may be open at once. A connection holds a permit while
/// it's open. A refused connection gives its permit back and lowers the limit by one in the same
/// step, so later connections wait for a free permit.
final class ConnectionGate: @unchecked Sendable {
    // @unchecked: every stored property is only read or written under `lock`.
    private let lock = NSLock()
    private var limit: Int
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int = .max) {
        self.limit = max(1, limit)
    }

    /// Sets the limit and lets waiters in if it allows more.
    func setLimit(_ newLimit: Int) {
        let resumed: [CheckedContinuation<Void, Error>] = lock.withLock {
            limit = max(1, newLimit)
            return admitWaiters()
        }
        resumed.forEach { $0.resume() }
    }

    /// Waits for a free permit. Throws `CancellationError` if the task is cancelled while waiting.
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Decided once, under the lock. A queued waiter is resumed by `release`,
                // `setLimit` or the cancellation handler, never here.
                enum Outcome { case admitted, cancelled, queued }
                let outcome: Outcome = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if inUse < limit && waiters.isEmpty {
                        inUse += 1
                        return .admitted
                    }
                    waiters.append((id, continuation))
                    return .queued
                }
                switch outcome {
                case .admitted: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .queued: break
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Gives a permit back. `lowering` also lowers the limit by one, never below 1
    /// (`SegmentPlanner.lowered`), for a connection the server refused.
    func release(lowering: Bool = false) {
        let resumed: [CheckedContinuation<Void, Error>] = lock.withLock {
            inUse -= 1
            if lowering { limit = SegmentPlanner.lowered(limit) }
            return admitWaiters()
        }
        resumed.forEach { $0.resume() }
    }

    /// Takes permits for waiters, in order, while the limit allows. Call under `lock`.
    private func admitWaiters() -> [CheckedContinuation<Void, Error>] {
        var resumed: [CheckedContinuation<Void, Error>] = []
        while inUse < limit, !waiters.isEmpty {
            inUse += 1
            resumed.append(waiters.removeFirst().continuation)
        }
        return resumed
    }
}
