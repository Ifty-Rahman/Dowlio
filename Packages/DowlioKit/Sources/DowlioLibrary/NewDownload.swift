import DowlioCore
import Foundation

/// Pasted or dropped text as the New Download sheet reads it: one link per line.
public enum PastedLinks {
    public enum Line: Equatable, Sendable {
        case link(URL)
        case notALink(String)
        /// A link Dowlio can't download, such as `ftp:` or `magnet:`.
        case unsupported(URL)

        public var url: URL? {
            if case .link(let url) = self { url } else { nil }
        }

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
        if inspection.isWebPage {
            self.init(line: "This link is a web page", reason: "Download saves the page as an .html file.", tone: .caution)
            return
        }
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

    /// A link that couldn't be checked. Where trying again later may work, the next step is
    /// Download Anyway, since the sheet has no Retry.
    public init(failure: DownloadError) {
        let text = FailureText(failure)
        switch failure {
        case .needsSignIn, .forbidden:
            self.init(
                line: "Needs your sign-in",
                reason: "This site only gives the file to signed-in visitors. Use the Dowlio button in your browser and allow sign-in sharing for this site.",
                tone: .problem
            )
        case .network, .tooManyRetries:
            self.init(line: text.reason, reason: "Download Anyway still adds it, and Dowlio tries again when it starts.", tone: .problem)
        default:
            self.init(line: text.reason, reason: text.nextStep, tone: .problem)
        }
    }
}

/// What the New Download sheet holds while the user fills it in.
public struct NewDownloadDraft: Equatable, Sendable {
    public enum Check: Equatable, Sendable {
        case checking
        case inspected(LinkInspection)
        case failed(DownloadError)

        public var status: LinkStatus {
            switch self {
            case .checking: .checking
            case .inspected(let inspection): LinkStatus(inspection)
            case .failed(let error): LinkStatus(failure: error)
            }
        }
    }

    public var text: String {
        didSet { lines = PastedLinks.parse(text) }
    }

    public private(set) var lines: [PastedLinks.Line]
    public var folder: URL
    public var connections = 8
    public var referrer = ""
    public var userAgent = ""
    public var startImmediately = true

    private var checks: [URL: (check: Check, headers: RequestOptions)] = [:]
    private var renamed: (url: URL, name: String)?
    private var cookiesByLink: [URL: [Cookie]] = [:]
    private var originByLink: [URL: DownloadOrigin] = [:]

    public init(text: String, folder: URL) {
        self.text = text
        self.folder = folder
        lines = PastedLinks.parse(text)
    }

    public var links: [URL] { lines.compactMap(\.url) }

    public mutating func append(_ more: String) {
        guard !more.isEmpty else { return }
        let current = text.trimmingCharacters(in: .newlines)
        text = current.isEmpty ? more : "\(current)\n\(more)"
    }

    public mutating func addSent(_ link: URL, referrer page: URL?, cookies: [Cookie] = [], browser: String? = nil) {
        if referrer.trimmingCharacters(in: .whitespaces).isEmpty, let page { referrer = page.absoluteString }
        if !cookies.isEmpty { cookiesByLink[link] = cookies }
        originByLink[link] = DownloadOrigin(kind: .sent, browser: browser)
        guard !links.contains(link) else { return }
        append(link.absoluteString)
    }

    public mutating func merge(_ other: NewDownloadDraft) {
        if referrer.trimmingCharacters(in: .whitespaces).isEmpty { referrer = other.referrer }
        cookiesByLink.merge(other.cookiesByLink) { _, new in new }
        originByLink.merge(other.originByLink) { _, new in new }
        append(other.text)
    }

    public mutating func grantSignIn(origin: URL, cookies: [Cookie]) {
        for link in links where Self.origin(of: link) == Self.origin(of: origin) {
            cookiesByLink[link] = cookies
        }
    }

    private static func origin(of url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host()?.lowercased() ?? "")"
    }

    public func origin(for url: URL) -> DownloadOrigin? {
        originByLink[url]
    }

    public func inspectionOptions(for url: URL) -> RequestOptions {
        var options = inspectionOptions
        options.cookies = cookiesByLink[url] ?? []
        return options
    }

    public func options(for url: URL) -> RequestOptions {
        var options = options
        options.cookies = cookiesByLink[url] ?? []
        return options
    }

    public var isSingleLink: Bool { links.count == 1 }

    public var canDownload: Bool { !links.isEmpty }

    /// Some link couldn't be checked, so Download adds it anyway.
    public var downloadsAnyway: Bool {
        links.contains { if case .failed = check(for: $0) { true } else { false } }
    }

    /// Why Download is off, once the field has text.
    public var explanation: String? {
        guard links.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Paste an http or https link, one per line."
    }

    public func check(for url: URL) -> Check? {
        checks[url]?.check
    }

    /// The single link's name: the user's edit, then the inspected name, then the link's own.
    public var fileName: String {
        guard isSingleLink, let url = links.first else { return "" }
        if let renamed, renamed.url == url { return renamed.name }
        if case .inspected(let inspection) = check(for: url) { return inspection.fileName }
        return url.lastPathComponent
    }

    public mutating func rename(_ name: String) {
        guard isSingleLink, let url = links.first else { return }
        renamed = (url, name)
    }

    /// The headers a check is made with. A change means every link needs checking again.
    public var inspectionOptions: RequestOptions {
        var options = RequestOptions()
        let referrer = referrer.trimmingCharacters(in: .whitespaces)
        options.referrer = URL(string: referrer).flatMap { $0.scheme == nil || $0.host() == nil ? nil : $0 }
        let agent = userAgent.trimmingCharacters(in: .whitespaces)
        options.userAgent = agent.isEmpty ? nil : agent
        return options
    }

    /// What Download adds each link with.
    public var options: RequestOptions {
        var options = inspectionOptions
        options.connections = connections
        if isSingleLink, let url = links.first, let renamed, renamed.url == url {
            let name = renamed.name.trimmingCharacters(in: .whitespaces)
            options.fileName = name.isEmpty ? nil : name
        }
        return options
    }

    /// The links that need checking now: new ones, and all of them after the headers changed.
    /// They're marked as checking, and links no longer in the field are forgotten.
    public mutating func linksToCheck() -> [URL] {
        let current = links
        checks = checks.filter { current.contains($0.key) }
        cookiesByLink = cookiesByLink.filter { current.contains($0.key) }
        originByLink = originByLink.filter { current.contains($0.key) }
        let due = current.filter { url in
            guard let existing = checks[url] else { return true }
            return existing.headers != inspectionOptions(for: url)
        }
        for url in due { checks[url] = (.checking, inspectionOptions(for: url)) }
        return due
    }

    /// Keeps a check's result, unless the link left the field or the headers changed since.
    public mutating func record(_ check: Check, for url: URL, checkedWith headers: RequestOptions) {
        guard let existing = checks[url], existing.headers == headers else { return }
        checks[url] = (check, headers)
    }

    public static func == (lhs: NewDownloadDraft, rhs: NewDownloadDraft) -> Bool {
        lhs.text == rhs.text && lhs.folder == rhs.folder && lhs.connections == rhs.connections
            && lhs.referrer == rhs.referrer && lhs.userAgent == rhs.userAgent && lhs.startImmediately == rhs.startImmediately
            && lhs.renamed?.url == rhs.renamed?.url && lhs.renamed?.name == rhs.renamed?.name
            && lhs.checks.mapValues(\.check) == rhs.checks.mapValues(\.check)
            && lhs.cookiesByLink == rhs.cookiesByLink && lhs.originByLink == rhs.originByLink
    }
}
