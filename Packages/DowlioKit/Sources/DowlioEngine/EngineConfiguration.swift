import Foundation

package struct EngineConfiguration: Sendable {
    package var retry = RetryPolicy()
    package var idleTimeout: Duration = .seconds(60)
    package var sessions = SessionMode.onePerConnection
    var now: @Sendable () -> Date = { Date() }
    var random: @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    var hostLimits: any HostLimitStore = InMemoryHostLimitStore()

    package init() {}
}

/// `oneShared` is only for the connection benchmark in `docs/benchmarks.md`. Never use it in the app.
package enum SessionMode: Sendable {
    case onePerConnection
    case oneShared
}

package struct RetryPolicy: Sendable {
    /// Per segment. One segment running out fails the whole download.
    package var maximumFailures = 5
    package var firstDelay: Duration = .seconds(1)
    package var maximumDelay: Duration = .seconds(30)
    package var jitter = 0.2
    package var maximumRetryAfter: Duration = .seconds(5 * 60)

    package init() {}

    package func delay(afterFailure failure: Int, retryAfter: Duration?, random: (ClosedRange<Double>) -> Double) -> Duration {
        if let retryAfter { return min(max(retryAfter, .zero), maximumRetryAfter) }
        let doubled = firstDelay * (1 << min(failure - 1, 30))
        let jittered = doubled * random((1 - jitter)...(1 + jitter))
        return min(jittered, maximumDelay)
    }
}

enum RetryAfter {
    static func parse(_ value: String?, now: Date) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return .seconds(max(seconds, 0)) }
        guard let date = httpDate.date(from: value) else { return nil }
        return .milliseconds(Int64(max(date.timeIntervalSince(now), 0) * 1000))
    }

    /// RFC 9110's preferred date format, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

extension URLError.Code {
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
