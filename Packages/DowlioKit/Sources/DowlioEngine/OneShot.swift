import Foundation

/// A signal that fires once. Waiters resume when it fires, and wait no longer after that.
final class OneShot: @unchecked Sendable {
    // @unchecked: `fired` and `waiters` are only read or written under `lock`.
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
