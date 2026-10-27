import DowlioCore
import Foundation
import os

public protocol SiteReader: Sendable {
    var name: String { get }
    func recognises(_ page: URL) -> Bool
    func post(in page: URL) -> String?
    func read(_ page: SitePage) async throws -> [SiteVideo]
}

public struct SitePage: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public var url: URL
    public var embeddedJSON: [String]
    public var html: String?
    public var cookies: [Cookie]
    private let fetch: Fetch

    public init(url: URL, embeddedJSON: [String] = [], html: String? = nil, cookies: [Cookie] = [], fetch: @escaping Fetch) {
        self.url = url
        self.embeddedJSON = embeddedJSON
        self.html = html
        self.cookies = cookies
        self.fetch = fetch
    }

    public var embeddedObjects: [Any] {
        embeddedJSON.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }

    public func json(at url: URL) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await fetch(url), options: [.fragmentsAllowed])
    }
}

public struct SiteVideo: Equatable, Sendable {
    public var label: String?
    public var thumbnail: URL?
    public var duration: Double?
    public var versions: [Version]
    public var streams: [URL]
    public var restriction: Candidate.Restriction?

    public init(
        label: String? = nil, thumbnail: URL? = nil, duration: Double? = nil, versions: [Version] = [], streams: [URL] = [],
        restriction: Candidate.Restriction? = nil
    ) {
        self.label = label
        self.thumbnail = thumbnail
        self.duration = duration
        self.versions = versions
        self.streams = streams
        self.restriction = restriction
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
    public static let all: [any SiteReader] = [XReader(), InstagramReader(), FacebookReader(), RedditReader(), ThreadsReader(), TikTokReader(), BlueskyReader(), TumblrReader(), PinterestReader()]
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
