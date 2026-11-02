import Foundation

enum BlockedPage {
    private static let markers = [
        "<title>just a moment",
        "<title>attention required! | cloudflare",
        "<title>access denied</title>",
        "cf-browser-verification",
        "/cdn-cgi/challenge-platform/h/",
        "checking your browser before accessing",
        "captcha-delivery.com",
        "px-captcha",
        "please verify you are a human",
    ]

    static func isChallenge(_ html: String) -> Bool {
        let head = html.prefix(65_536).lowercased()
        return markers.contains { head.contains($0) }
    }

    static let longestWait = Duration.seconds(30)
    static let defaultWait = Duration.seconds(10)

    static func wait(from retryAfter: String?) -> Duration {
        guard let seconds = retryAfter.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else { return defaultWait }
        return min(.seconds(seconds), longestWait)
    }
}

public actor HostCooldown {
    private var until: [String: ContinuousClock.Instant] = [:]

    public init() {}

    public func cool(_ host: String, for wait: Duration) {
        let end = ContinuousClock.now + wait
        if let current = until[host], current >= end { return }
        until[host] = end
    }

    public func remaining(_ host: String) -> Duration {
        guard let end = until[host] else { return .zero }
        return max(.zero, end - .now)
    }

    func wait(for host: String) async {
        let left = remaining(host)
        guard left > .zero else { return }
        try? await Task.sleep(for: left)
    }
}
