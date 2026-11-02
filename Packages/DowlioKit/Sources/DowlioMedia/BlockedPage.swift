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

    static let largestHead = 65_536

    static func isChallenge(_ html: String) -> Bool {
        let head = html.prefix(largestHead).lowercased()
        return markers.contains { head.contains($0) }
    }

    static let longestWait = Duration.seconds(30)
    static let defaultWait = Duration.seconds(10)

    static func wait(from retryAfter: String?) -> Duration {
        guard let seconds = retryAfter.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else { return defaultWait }
        return min(.seconds(seconds), longestWait)
    }
}
