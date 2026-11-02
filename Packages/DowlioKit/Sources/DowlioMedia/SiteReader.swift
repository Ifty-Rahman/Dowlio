import DowlioCore
import Foundation
import os

public protocol SiteReader: Sendable {
    var name: String { get }
    func recognises(_ page: URL) -> Bool
    func post(in page: URL) -> String?
    func read(_ page: SitePage) async throws -> [SiteVideo]
    func recognisesPlayer(in html: String) -> Bool
    func embeds(in html: String) -> [URL]
}

extension SiteReader {
    public func recognisesPlayer(in html: String) -> Bool { false }
    public func embeds(in html: String) -> [URL] { [] }
}

enum EmbedAddresses {
    static func found(_ pattern: NSRegularExpression, in html: String, address: (String) -> URL?) -> [URL] {
        let text = ScriptMedia.unescaped(html)
        let ns = text as NSString
        var found: [URL] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = address(ns.substring(with: match.range(at: 1))), !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }
}

public struct SitePage: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Send = @Sendable (URL, Data?, [String: String]) async throws -> Data

    public var url: URL
    public var embeddedJSON: [String]
    public var html: String?
    public var cookies: [Cookie]
    public var framedBy: URL?
    private let fetch: Fetch
    private let send: Send?

    public init(
        url: URL, embeddedJSON: [String] = [], html: String? = nil, cookies: [Cookie] = [], framedBy: URL? = nil, send: Send? = nil,
        fetch: @escaping Fetch
    ) {
        self.url = url
        self.embeddedJSON = embeddedJSON
        self.html = html
        self.cookies = cookies
        self.framedBy = framedBy
        self.send = send
        self.fetch = fetch
    }

    public var embeddedObjects: [Any] {
        embeddedJSON.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }

    public func json(at url: URL) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await fetch(url), options: [.fragmentsAllowed])
    }

    public func json(posting body: [String: Any], to url: URL) async throws -> Any {
        guard let send else { throw SiteReaderError.unreadable }
        let sent = try JSONSerialization.data(withJSONObject: body)
        return try JSONSerialization.jsonObject(with: try await send(url, sent, ["Content-Type": "application/json"]), options: [.fragmentsAllowed])
    }

    public func json(posting body: [String: Any], to url: URL, headers: [String: String]) async throws -> Any {
        guard let send else { throw SiteReaderError.unreadable }
        let sent = try JSONSerialization.data(withJSONObject: body)
        return try JSONSerialization.jsonObject(
            with: try await send(url, sent, headers.merging(["Content-Type": "application/json"]) { first, _ in first }), options: [.fragmentsAllowed]
        )
    }

    public func json(at url: URL, headers: [String: String]) async throws -> Any {
        guard let send else { throw SiteReaderError.unreadable }
        return try JSONSerialization.jsonObject(with: try await send(url, nil, headers), options: [.fragmentsAllowed])
    }

    public func text(at url: URL) async throws -> String {
        String(decoding: try await fetch(url), as: UTF8.self)
    }
}

public struct SiteVideo: Equatable, Sendable {
    public var label: String?
    public var thumbnail: URL?
    public var duration: Double?
    public var versions: [Version]
    public var streams: [URL]
    public var restriction: Candidate.Restriction?
    public var rules: RequestRules?

    public init(
        label: String? = nil, thumbnail: URL? = nil, duration: Double? = nil, versions: [Version] = [], streams: [URL] = [],
        restriction: Candidate.Restriction? = nil, rules: RequestRules? = nil
    ) {
        self.label = label
        self.thumbnail = thumbnail
        self.duration = duration
        self.versions = versions
        self.streams = streams
        self.restriction = restriction
        self.rules = rules
    }
}

public struct RequestRules: Equatable, Sendable {
    public var referrer: URL?
    public var origin: String?
    public var userAgent: String?

    public init(referrer: URL? = nil, origin: String? = nil, userAgent: String? = nil) {
        self.referrer = referrer
        self.origin = origin
        self.userAgent = userAgent
    }

    func applied(to options: RequestOptions) -> RequestOptions {
        var options = options
        if let referrer { options.referrer = referrer }
        if let origin { options.origin = origin }
        if let userAgent { options.userAgent = userAgent }
        return options
    }

    func applied(to version: Version) -> Version {
        var version = version
        version.referrer = version.referrer ?? referrer
        version.origin = version.origin ?? origin
        version.userAgent = version.userAgent ?? userAgent
        return version
    }
}

public enum SiteReaderError: Error, Equatable {
    case refused(status: Int)
    case unreadable
}

public struct ReaderFailure: Equatable, Sendable {
    public var reader: String
    public var site: String
    public var reason: String

    public init(reader: String, site: String, reason: String) {
        self.reader = reader
        self.site = site
        self.reason = reason
    }

    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "site-readers")

    public static let log: @Sendable (ReaderFailure) -> Void = { failure in
        logger.notice("\(failure.reader, privacy: .public) reader on \(failure.site, privacy: .public): \(failure.reason, privacy: .public)")
    }
}

public enum SiteReaders {
    public static let all: [any SiteReader] = [
        XReader(), InstagramReader(), FacebookReader(), RedditReader(), RedGifsReader(), ThreadsReader(), BlueskyReader(), TumblrReader(), PinterestReader(),
        LinkedInReader(), SnapchatReader(), VimeoReader(), DailymotionReader(), StreamableReader(), LoomReader(),
        WistiaReader(), BrightcoveReader(), KalturaReader(), VidyardReader(),
        ImgurReader(), TelegramReader(), AnimatedPostReader.nineGag(), AnimatedPostReader.tenor(), AnimatedPostReader.giphy(), VKReader(), OKReader(),
        MastodonReader(), TwitchReader(), KickReader(), RumbleReader(), SoundCloudReader(), BandcampReader(), MixcloudReader(),
    ] + WebPlayerReader.all
}

enum PostLabel {
    static let words = 8
    static let length = 60

    static func of(text: String?, author: String?) -> String? {
        let squashed = squash(text)
        let name = squash(author)
        guard !squashed.isEmpty else { return name.isEmpty ? nil : shorten(name) }
        let start = squashed.split(separator: " ").prefix(words).joined(separator: " ")
        return shorten(name.isEmpty || start.hasPrefix(name) ? start : "\(name): \(start)")
    }

    static func shorten(_ text: String) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func squash(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func objects(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    func list(_ key: String) -> [Any] {
        self[key] as? [Any] ?? []
    }

    func text(_ key: String) -> String? {
        (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func pathComponent(after markers: Set<String>) -> String? {
        let parts = Array(pathComponents.dropFirst())
        guard let index = parts.firstIndex(where: markers.contains), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }

    func isOn(_ hosts: Set<String>) -> Bool {
        guard let host = host(percentEncoded: false)?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    init?(json value: Any?) {
        guard let text = value as? String, !text.isEmpty, let url = URL(string: text), url.scheme != nil else { return nil }
        self = url
    }
}

func shorterSide(_ width: Any?, _ height: Any?) -> Int? {
    guard let width = jsonNumber(width), let height = jsonNumber(height), width > 0, height > 0 else { return nil }
    return Int(min(width, height))
}

func jsonNumber(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
}
