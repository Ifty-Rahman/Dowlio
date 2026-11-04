import Foundation

public enum YTDLPFailure: Error, Equatable, Hashable, Sendable {
    case unsupportedSite
    case needsSignIn
    case `private`
    case geoBlocked
    case protected
    case rateLimited
    case extractorBroken
    case network
    case live
    case unavailable

    static func classify(_ errorText: String) -> YTDLPFailure {
        let lines = errorText.split(whereSeparator: \.isNewline).map(String.init)
        let message = (lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "").lowercased()
        let all = errorText.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { message.contains($0) } }
        if has("drm protected") { return .protected }
        if has("private video", "this video is private") { return .private }
        if has("live event will begin", "premieres in", "this live event", "is live now", "is currently live") { return .live }
        if has("not available in your country", "not made this video available in your country", "geo restriction", "geo-restricted") {
            return .geoBlocked
        }
        if has("http error 429", "too many requests", "try again later", "not a bot", "rate-limited", "rate limited") { return .rateLimited }
        if has("sign in", "login required", "log in", "logged-in", "members-only", "join this channel", "authentication") { return .needsSignIn }
        if has("unsupported url") { return .unsupportedSite }
        if has("video unavailable", "video is unavailable", "has been removed", "no longer available", "does not exist") { return .unavailable }
        if has(
            "unable to connect", "failed to resolve", "nodename nor servname", "timed out", "connection refused", "connection reset",
            "network is unreachable", "temporary failure in name resolution", "no route to host", "ssl"
        ) || all.contains("transporterror") {
            return .network
        }
        if message.contains("[generic]") { return .unsupportedSite }
        return .extractorBroken
    }
}
