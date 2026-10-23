import Foundation

/// How the engine times its retries. Tests inject shorter waits, a fixed clock and fixed jitter.
/// The app uses the defaults.
package struct EngineConfiguration: Sendable {
    package var retry = RetryPolicy()
    /// A connection that receives nothing for this long counts as failed, and is retried.
    package var idleTimeout: Duration = .seconds(60)
    /// The current time, for the next try's time in Retrying and for `Retry-After` dates.
    var now: @Sendable () -> Date = { Date() }
    /// A random number in the range, for jitter.
    var random: @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    /// The connection limits learned per host, shared by every download of the engine.
    var hostLimits: any HostLimitStore = InMemoryHostLimitStore()

    package init() {}
}

/// When to try a failed connection again (spec, retry policy).
package struct RetryPolicy: Sendable {
    /// Failures of one segment before the whole download becomes Failed.
    var maximumFailures = 5
    /// The wait before the first retry. Each later wait doubles.
    package var firstDelay: Duration = .seconds(1)
    /// The longest wait between two tries, after jitter.
    package var maximumDelay: Duration = .seconds(30)
    /// How far each wait may vary either way, as a fraction of it.
    var jitter = 0.2
    /// The longest wait a server's `Retry-After` can ask for.
    var maximumRetryAfter: Duration = .seconds(5 * 60)

    /// The wait after the `failure`th failure in a row, counting from 1. A server's `Retry-After`
    /// replaces the computed wait.
    func delay(afterFailure failure: Int, retryAfter: Duration?, random: (ClosedRange<Double>) -> Double) -> Duration {
        if let retryAfter { return min(max(retryAfter, .zero), maximumRetryAfter) }
        let doubled = firstDelay * (1 << min(failure - 1, 30))
        let jittered = doubled * random((1 - jitter)...(1 + jitter))
        return min(jittered, maximumDelay)
    }
}

enum RetryAfter {
    /// Parses `Retry-After` as seconds or as an HTTP date, relative to `now`.
    static func parse(_ value: String?, now: Date) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return .seconds(max(seconds, 0)) }
        guard let date = httpDate.date(from: value) else { return nil }
        return .milliseconds(Int64(max(date.timeIntervalSince(now), 0) * 1000))
    }

    /// RFC 9110's preferred date format, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static var httpDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}

extension URLError.Code {
    /// Network failures that another try may get past. Bad URLs, certificate problems and
    /// cancellation aren't among them.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
             .cannotParseResponse, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            true
        default:
            false
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
