import DowlioCore
import Foundation

public struct SentPage: Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var browser: String?
    public var cookies: [Cookie]
    public var userAgent: String?
    public var scan: [ScannedMedia]
    public var players: [ScannedPlayer]
    public var embeddedJSON: [String]
    public var watched: [WatchedRequest]
    public var throughDowlioConnect: Bool

    public init(
        url: URL,
        title: String? = nil,
        browser: String? = nil,
        cookies: [Cookie] = [],
        userAgent: String? = nil,
        scan: [ScannedMedia] = [],
        players: [ScannedPlayer] = [],
        embeddedJSON: [String] = [],
        watched: [WatchedRequest] = [],
        throughDowlioConnect: Bool = false
    ) {
        self.url = url
        self.title = title
        self.browser = browser
        self.cookies = cookies
        self.userAgent = userAgent
        self.scan = scan
        self.players = players
        self.embeddedJSON = embeddedJSON
        self.watched = watched
        self.throughDowlioConnect = throughDowlioConnect
    }
}

public struct WatchedRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case manifest
        case file
    }

    public var url: URL
    public var kind: Kind
    public var contentType: String?
    public var referrer: URL?

    public init(url: URL, kind: Kind, contentType: String? = nil, referrer: URL? = nil) {
        self.url = url
        self.kind = kind
        self.contentType = contentType
        self.referrer = referrer
    }
}

public struct ScannedPlayer: Equatable, Sendable {
    public var group: Int
    public var label: String?
    public var poster: URL?
    public var duration: Double?
    public var isPlaying: Bool
    public var visibility: Double
    /// The origin of the frame the player is in, which is what the browser names as the referrer
    /// of the streams it plays.
    public var origin: URL?

    public init(
        group: Int, label: String? = nil, poster: URL? = nil, duration: Double? = nil, isPlaying: Bool = false, visibility: Double = 0,
        origin: URL? = nil
    ) {
        self.group = group
        self.origin = origin
        self.label = label
        self.poster = poster
        self.duration = duration
        self.isPlaying = isPlaying
        self.visibility = visibility
    }
}

public struct ScannedMedia: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case video
        case audio
    }

    public var url: URL
    public var kind: Kind
    public var poster: URL?
    public var duration: Double?
    public var group: Int?
    public var height: Int?
    public var codecs: String?

    public init(
        url: URL, kind: Kind, poster: URL? = nil, duration: Double? = nil, group: Int? = nil, height: Int? = nil, codecs: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.poster = poster
        self.duration = duration
        self.group = group
        self.height = height
        self.codecs = codecs
    }
}

public struct Candidate: Equatable, Sendable {
    public enum Restriction: Hashable, Sendable {
        case protected
        case live
    }

    public var label: String
    public var thumbnail: URL?
    public var duration: Double?
    public var versions: [Version]
    public var restriction: Restriction?
    public var isOnScreen: Bool
    public var isOther: Bool
    public var unprobed: [WatchedRequest]

    public init(
        label: String, thumbnail: URL? = nil, duration: Double? = nil, versions: [Version], restriction: Restriction? = nil,
        isOnScreen: Bool = false, isOther: Bool = false, unprobed: [WatchedRequest] = []
    ) {
        self.label = label
        self.thumbnail = thumbnail
        self.duration = duration
        self.versions = versions
        self.restriction = restriction
        self.isOnScreen = isOnScreen
        self.isOther = isOther
        self.unprobed = unprobed
    }

    public var needsProbe: Bool {
        versions.isEmpty && restriction == nil && !unprobed.isEmpty
    }
}

public struct Version: Equatable, Sendable {
    public var source: DownloadSource
    public var contentType: String?
    public var totalBytes: Int64?
    public var isEstimatedSize: Bool
    public var height: Int?
    public var codecs: String?
    public var language: String?
    public var referrer: URL?
    public var userAgent: String?

    public init(
        source: DownloadSource,
        contentType: String? = nil,
        totalBytes: Int64? = nil,
        isEstimatedSize: Bool = false,
        height: Int? = nil,
        codecs: String? = nil,
        language: String? = nil,
        referrer: URL? = nil,
        userAgent: String? = nil
    ) {
        self.source = source
        self.contentType = contentType
        self.totalBytes = totalBytes
        self.isEstimatedSize = isEstimatedSize
        self.height = height
        self.codecs = codecs
        self.language = language
        self.referrer = referrer
        self.userAgent = userAgent
    }
}

public enum PageAnalysis: Equatable, Sendable {
    case looking([Candidate])
    case playing
    case needsSignIn
    case plainFile(URL)
    case found([Candidate])
}
