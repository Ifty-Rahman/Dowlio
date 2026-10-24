import DowlioCore
import Foundation

/// Pasted or dropped text as the New Download sheet reads it: one link per line.
public enum PastedLinks {
    public enum Line: Equatable, Sendable {
        case link(URL)
        case notALink(String)
        /// A link Dowlio can't download, such as `ftp:` or `magnet:`.
        case unsupported(URL)

        /// Why the line is skipped, or `nil` for a link Dowlio downloads.
        public var problem: String? {
            switch self {
            case .link: nil
            case .notALink: "Not a link"
            case .unsupported: "Dowlio downloads http and https links"
            }
        }
    }

    /// Every non-blank line in order, with a repeated link merged into its first appearance.
    public static func parse(_ text: String) -> [Line] {
        var seen: Set<String> = []
        var lines: [Line] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let line = Self.line(trimmed)
            if case .link(let url) = line {
                guard seen.insert(url.absoluteString).inserted else { continue }
            }
            lines.append(line)
        }
        return lines
    }

    public static func links(in text: String) -> [URL] {
        parse(text).compactMap { if case .link(let url) = $0 { url } else { nil } }
    }

    private static func line(_ text: String) -> Line {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return .notALink(text) }
        guard ["http", "https"].contains(scheme) else { return .unsupported(url) }
        guard let host = url.host(), !host.isEmpty else { return .notALink(text) }
        return .link(url)
    }
}

/// The file card's status line for one link, and its colour.
public struct LinkStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral
        case good
        case caution
        case problem
    }

    public var line: String
    public var reason: String?
    public var tone: Tone

    public init(line: String, reason: String?, tone: Tone) {
        self.line = line
        self.reason = reason
        self.tone = tone
    }

    public static let checking = LinkStatus(line: "Checking link…", reason: nil, tone: .neutral)

    public init(_ inspection: LinkInspection) {
        switch (inspection.splitsIntoSegments, inspection.cannotResumeBecause) {
        case (true, nil):
            self.init(line: "Resumable, splits into segments", reason: nil, tone: .good)
        case (true, .some):
            self.init(
                line: "Splits into segments, but can't resume",
                reason: "The server can't confirm the file stays the same, so pausing starts it over.", tone: .caution
            )
        case (false, .sizeUnknown):
            self.init(
                line: "Single connection only",
                reason: "The server doesn't say how big the file is, so pausing starts it over.", tone: .caution
            )
        case (false, _):
            self.init(
                line: "Single connection only",
                reason: "The server sends the whole file in one piece, so pausing starts it over.", tone: .caution
            )
        }
    }

    public init(failure: DownloadError) {
        let text = FailureText(failure)
        self.init(line: text.reason, reason: text.nextStep, tone: .problem)
    }
}
