import DowlioCore
import Foundation

extension DownloadRun {
    enum RetryKey: Hashable {
        case probe
        case whole
        case segment(Int)
    }

    func withRetries<T: Sendable>(_ key: RetryKey, host: URL, _ work: () async throws -> T) async throws -> T {
        let policy = configuration.retry
        var failures = 0
        while true {
            do {
                return try await work()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard let retryable = RetryableFailure(classifying: error) else { throw error }
                if retryable.isRefusal { lowerLimit(of: host) }
                failures += 1
                guard failures < policy.maximumFailures else { throw DownloadError.tooManyRetries }

                let delay = policy.delay(afterFailure: failures, retryAfter: retryable.retryAfter, random: configuration.random)
                retries.begin(key, attempt: failures, nextTry: configuration.now().addingTimeInterval(delay.timeInterval))
                await publishRetryState()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    retries.end(key)
                    throw error
                }
                retries.end(key)
                await publishRetryState()
            }
        }
    }

    private func lowerLimit(of host: URL) {
        guard let key = host.hostLimitKey else { return }
        let connections = options.connections
        configuration.hostLimits.updateLimit(for: key) { SegmentPlanner.lowered($0 ?? connections) }
    }

    private func publishRetryState() async {
        let retries = retries
        await changeSnapshot { snapshot in
            if snapshot.state.isFetching { snapshot.state = retries.state ?? .downloading }
        }
    }
}

struct RetryableFailure: Error {
    var retryAfter: Duration?
    /// A 429, a 503 or a reset connection, so the host gets one connection fewer.
    var isRefusal = false
}

extension RetryableFailure {
    init?(classifying error: Error) {
        if let retryable = error as? RetryableFailure {
            self = retryable
        } else if let error = error as? URLError, error.code.isRetryable {
            self.init(isRefusal: error.code == .networkConnectionLost)
        } else {
            return nil
        }
    }

    static func throwIfEndedEarly(received: Int64, expected: Int64?) throws {
        try Task.checkCancellation()
        if let expected, received < expected { throw RetryableFailure() }
    }
}

final class RetryTracker: @unchecked Sendable {
    // @unchecked: `waits` is only read or written under `lock`.
    private let lock = NSLock()
    private var waits: [DownloadRun.RetryKey: (attempt: Int, nextTry: Date)] = [:]

    func begin(_ key: DownloadRun.RetryKey, attempt: Int, nextTry: Date) {
        lock.withLock { waits[key] = (attempt, nextTry) }
    }

    func end(_ key: DownloadRun.RetryKey) {
        _ = lock.withLock { waits.removeValue(forKey: key) }
    }

    var state: DownloadState? {
        lock.withLock {
            guard let attempt = waits.values.map(\.attempt).max(),
                  let nextTry = waits.values.map(\.nextTry).min() else { return nil }
            return .retrying(attempt: attempt, nextTry: nextTry)
        }
    }
}
