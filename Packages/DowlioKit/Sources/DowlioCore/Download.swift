import Foundation

/// Identifies one download, in the sense of `GLOSSARY.md`.
public struct DownloadID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Where a download is in its life. The interface shows `probing` and `finalizing` as Downloading.
public enum DownloadState: Equatable, Sendable {
    case probing
    case downloading
    case finalizing
    case completed
    case failed(DownloadError)
    /// The user cancelled the download. Its partial file is gone and the engine forgets it.
    case cancelled
    /// Waiting before trying a failed connection again. `attempt` counts the failures in a row,
    /// from 1. `nextTry` is when the next try starts. With several connections waiting, it shows
    /// the highest attempt and the earliest next try.
    case retrying(attempt: Int, nextTry: Date)
    /// The user paused the download. Resume continues it from the bytes it has.
    case paused

    /// No further snapshots follow a terminal state. Failed isn't terminal, because Retry
    /// continues a failed download (`GLOSSARY.md`), so its snapshot stream stays open.
    public var isTerminal: Bool {
        self == .completed || self == .cancelled
    }

    /// Probing, Downloading or Retrying: the download's connections are fetching, or about to.
    public var isFetching: Bool {
        switch self {
        case .probing, .downloading, .retrying: true
        default: false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

/// Why a download failed. Each case maps to one sentence of user copy in the interface.
public enum DownloadError: Error, Equatable, Sendable {
    case destinationNotWritable
    /// The server sent fewer bytes than the file's size, so the file isn't complete.
    case incompleteFile
    /// The connection failed in a way retrying can't fix, or the server answered with a status
    /// Dowlio doesn't expect.
    case network(NetworkFailure)
    /// The destination volume can't hold the whole file.
    case notEnoughSpace
    /// The server wants a signed-in visitor (401).
    case needsSignIn
    /// The server refuses to give the file (403).
    case forbidden
    /// The server has no such file (404 or 410).
    case notFound
    /// One segment failed 5 times in a row. The partial file stays, so Retry continues it.
    case tooManyRetries
    /// On resume, neither the original link nor the last final link gives the file any more.
    case linkExpired
    /// The file changed on the server twice in a row while downloading, so Dowlio stopped instead
    /// of mixing versions.
    case serverChangedFile
    case mediaUnplayable
    case needsTools
}

public enum RenewalFailure: Error, Equatable, Sendable {
    case toolsMissing
    case needsSignIn
    case network
    case failed
}

/// What went wrong with the network: the URL loading system's error code and its description.
public struct NetworkFailure: Equatable, Sendable, CustomStringConvertible {
    /// The underlying `URLError`'s code. `badServerResponse` for a status Dowlio doesn't expect,
    /// `unknown` for an error that isn't a `URLError`.
    public var code: URLError.Code
    /// The underlying error's description, for logs and developer tools.
    public var message: String

    public init(code: URLError.Code, message: String) {
        self.code = code
        self.message = message
    }

    /// The failure `error` stands for, keeping its `URLError` code when it has one.
    public init(_ error: Error) {
        let code = (error as? URLError)?.code ?? .unknown
        self.init(code: code, message: error.localizedDescription)
    }

    public var description: String { message }
}

/// How a download should run.
public struct RequestOptions: Equatable, Sendable {
    /// Connections per download, 1 to 16. Values outside that range are clamped.
    public var connections: Int = 8
    public var openExtraConnections: OpenExtraConnections = .afterFirstConnectionStarts

    public init() {}

    /// What happens when a file with the finished file's name already exists.
    public var nameConflictPolicy: NameConflictPolicy = .keepBoth

    /// Sent as `Referer` on every request. Some servers only give the file to visitors who come
    /// from their own page.
    public var referrer: URL?
    /// Sent as `Origin` on every request when set, for media a site's player reads from another
    /// origin. Otherwise a player's request takes the referrer's origin.
    public var origin: String?
    /// Sent as `User-Agent` on every request when set. Otherwise the system's default is sent.
    public var userAgent: String?
    /// Sent as one `Cookie` header on every request, for servers that only give the file to a
    /// signed-in visitor. Held in memory only: they never go into the partial file, so a restored
    /// download has none.
    public var cookies: [Cookie] = []
    public var browserRequest: BrowserRequest?
    /// How many failed attempts in a row one segment may have before the download is Failed, up
    /// to 11, which is ten retries. `nil` uses the engine's own default of 5.
    public var maximumFailures: Int?
    /// A connection that finishes its segment takes over half of the slowest segment's remaining
    /// work. With this off, each connection closes when its own segment is done.
    public var allowsWorkStealing = true
    public var requestSizeLimit: Int64?
    /// The name the user chose for the finished file. Unsafe characters are removed. `nil` takes
    /// the name the server or the link gives.
    public var fileName: String?
}

public struct DownloadOrigin: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case caught
        case sent
    }

    public var kind: Kind
    public var browser: String?

    public init(kind: Kind, browser: String?) {
        self.kind = kind
        self.browser = browser
    }
}

/// One cookie a download sends, as the browser had it for the download's link.
public struct Cookie: Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var hostOnly: Bool
    public var secure: Bool
    public var httpOnly: Bool

    public init(name: String, value: String, domain: String? = nil, path: String? = nil, hostOnly: Bool = false, secure: Bool = false, httpOnly: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.hostOnly = hostOnly
        self.secure = secure
        self.httpOnly = httpOnly
    }

    public func isSent(to url: URL, from origin: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        if secure, scheme != "https" { return false }
        if let path, path.count > 1, !Self.pathMatches(url.path(percentEncoded: true), path) { return false }
        guard let domain = domain?.lowercased(), !domain.isEmpty else {
            return host == origin.host(percentEncoded: false)?.lowercased()
        }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        if hostOnly { return host == bare }
        return host == bare || host.hasSuffix("." + bare)
    }
}

extension Cookie {
    static func pathMatches(_ requested: String, _ path: String) -> Bool {
        let requested = requested.isEmpty ? "/" : requested
        guard requested.hasPrefix(path) else { return false }
        return requested.count == path.count || path.hasSuffix("/") || requested.dropFirst(path.count).first == "/"
    }
}

extension Array where Element == Cookie {
    public func sent(to url: URL, from origin: URL) -> [Cookie] {
        filter { $0.isSent(to: url, from: origin) }
    }
}

public struct BrowserRequest: Equatable, Sendable {
    public var method: String
    public var body: Data?
    public var headers: [Header]

    public init(method: String = "GET", body: Data? = nil, headers: [Header] = []) {
        self.method = method
        self.body = body
        self.headers = headers
    }

    public var isEmpty: Bool { method == "GET" && body == nil && headers.isEmpty }
}

public struct Header: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// What to do when the destination already has a file with the finished file's name.
public enum NameConflictPolicy: String, Codable, Equatable, Sendable {
    /// Save the new file as "name 2.ext", "name 3.ext" and so on.
    case keepBoth
    /// Overwrite the existing file. The interface confirms this first.
    case replace
    /// Keep the existing file. The download completes without moving the new file in.
    case skip
}

/// When a download opens its connections after the first one.
public enum OpenExtraConnections: Equatable, Sendable {
    /// After the first connection starts receiving data, so a broken link costs one request.
    case afterFirstConnectionStarts
    case allAtOnce
}

/// One segment's progress, for the segmented bar.
public struct SegmentProgress: Equatable, Sendable {
    /// The segment's first byte.
    public var start: Int64
    /// The segment's last byte, inclusive.
    public var end: Int64
    public var receivedBytes: Int64
    /// Whether a connection is fetching this segment now.
    public var isActive: Bool

    public init(start: Int64, end: Int64, receivedBytes: Int64 = 0, isActive: Bool = false) {
        self.start = start
        self.end = end
        self.receivedBytes = receivedBytes
        self.isActive = isActive
    }
}

/// What the engine reports about one download.
public struct DownloadSnapshot: Equatable, Sendable {
    public var id: DownloadID
    public var state: DownloadState
    /// The name the finished file has, or will have.
    public var fileName: String
    public var destinationFolder: URL
    public var receivedBytes: Int64
    /// `nil` while the size is unknown.
    public var totalBytes: Int64?
    /// One entry per segment, in file order. Empty while the size is unknown.
    public var segments: [SegmentProgress] = []
    /// The segments as planned when the download started or last started over. Work stealing
    /// splits `segments`, never these.
    public var plannedSegments: [SegmentBounds] = []
    public var activeConnections: Int = 0
    /// Speed smoothed over the last 5 seconds.
    public var bytesPerSecond: Int64 = 0
    /// Seconds left at the current speed. `nil` while the size or the speed is unknown.
    public var timeRemaining: TimeInterval?
    /// The download uses plain HTTP, so its bytes travel unencrypted (ADR 0003).
    public var isNotSecure: Bool
    /// Whether pausing keeps the bytes downloaded so far. False when the server doesn't support
    /// ranges, the size is unknown, or the server sent no strong `ETag` or `Last-Modified`, so the
    /// interface can warn before a pause starts it over.
    public var canResume: Bool = false
    /// The download completed without moving its file in, because the name conflict policy is skip
    /// and a file with its name already existed. `fileName` is the download's own planned name,
    /// which the existing file has.
    public var wasSkipped: Bool = false
    /// The Category, from the name and the server's content type. `nil` until the probe answers,
    /// and for a file that matches no Category.
    public var category: FileCategory?
    /// The original link's host, lowercased, for showing where the download comes from. It stays
    /// the same when redirects lead elsewhere. `nil` for a link without a host.
    public var displayHost: String?
    public var renewedMedia: MediaSource?

    public init(
        id: DownloadID,
        state: DownloadState,
        fileName: String,
        destinationFolder: URL,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        isNotSecure: Bool = false,
        displayHost: String? = nil
    ) {
        self.id = id
        self.state = state
        self.fileName = fileName
        self.destinationFolder = destinationFolder
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.isNotSecure = isNotSecure
        self.displayHost = displayHost
    }
}

/// Where one segment starts and ends, without its progress. Bytes from `start` to `end` inclusive.
public struct SegmentBounds: Codable, Equatable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}
