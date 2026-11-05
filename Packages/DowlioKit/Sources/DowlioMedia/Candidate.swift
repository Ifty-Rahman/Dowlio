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
    public var framedBy: URL?

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
        throughDowlioConnect: Bool = false,
        framedBy: URL? = nil
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
        self.framedBy = framedBy
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
        case needsPassword
    }

    public var label: String
    public var thumbnail: URL?
    public var duration: Double?
    public var versions: [Version]
    public var restriction: Restriction?
    public var isOnScreen: Bool
    public var isOther: Bool
    public var unprobed: [WatchedRequest]
    public var opensAsAudio: Bool
    public var playlistOffer: PlaylistOffer?

    public init(
        label: String, thumbnail: URL? = nil, duration: Double? = nil, versions: [Version], restriction: Restriction? = nil,
        isOnScreen: Bool = false, isOther: Bool = false, unprobed: [WatchedRequest] = [], opensAsAudio: Bool = false
    ) {
        self.opensAsAudio = opensAsAudio
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
    public var frameRate: Int?
    public var codecs: String?
    public var language: String?
    public var referrer: URL?
    public var origin: String?
    public var userAgent: String?
    public var isHDR: Bool
    public var requestSizeLimit: Int64?

    public init(
        source: DownloadSource,
        contentType: String? = nil,
        totalBytes: Int64? = nil,
        isEstimatedSize: Bool = false,
        height: Int? = nil,
        codecs: String? = nil,
        language: String? = nil,
        referrer: URL? = nil,
        origin: String? = nil,
        userAgent: String? = nil,
        isHDR: Bool = false,
        requestSizeLimit: Int64? = nil,
        frameRate: Int? = nil
    ) {
        self.frameRate = frameRate
        self.source = source
        self.contentType = contentType
        self.totalBytes = totalBytes
        self.isEstimatedSize = isEstimatedSize
        self.height = height
        self.codecs = codecs
        self.language = language
        self.referrer = referrer
        self.origin = origin
        self.userAgent = userAgent
        self.isHDR = isHDR
        self.requestSizeLimit = requestSizeLimit
    }

    private var mediaSource: MediaSource? {
        if case .media(let media) = source { media } else { nil }
    }

    public var outputContainer: MediaContainer? { mediaSource?.container }

    public var resolution: String? {
        height.map { Self.resolution(height: $0, frameRate: frameRate) }
    }

    public var isHighFrameRate: Bool { (frameRate ?? 0) > 30 }

    public static func resolution(height: Int, frameRate: Int?) -> String {
        guard let frameRate, frameRate > 30 else { return "\(height)p" }
        return "\(height)p\(frameRate)"
    }

    public var expiry: Date? { mediaSource?.expiry }

    public var renewal: MediaRenewal? { mediaSource?.renewal }
}

public enum PageAnalysis: Equatable, Sendable {
    case looking([Candidate])
    case checkingForMore([Candidate])
    case playing
    case needsSignIn
    case blocked
    case plainFile(URL)
    case found([Candidate])
    case needsTools
    case toolsChanged
    case ytdlpFailed(YTDLPFailure)
    case playlist(PlaylistListing)
}

public struct PlaylistOffer: Equatable, Sendable {
    public var url: URL
    public var count: Int

    public init(url: URL, count: Int) {
        self.url = url
        self.count = count
    }
}

public struct PlaylistListing: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var videoID: String
        public var position: Int
        public var title: String
        public var url: URL
        public var duration: Double?
        public var thumbnail: URL?
        public var isAvailable: Bool

        public var id: String { "\(position)-\(videoID)" }

        public init(
            id videoID: String, position: Int, title: String, url: URL, duration: Double? = nil, thumbnail: URL? = nil, isAvailable: Bool = true
        ) {
            self.videoID = videoID
            self.position = position
            self.title = title
            self.url = url
            self.duration = duration
            self.thumbnail = thumbnail
            self.isAvailable = isAvailable
        }
    }

    public var title: String
    public var url: URL
    public var entries: [Entry]
    public var total: Int?
    public var isMusic: Bool
    public var isCut: Bool
    public var channel: String?
    public var thumbnail: URL?
    public var updated: Date?
    public var heights: [Int]?
    public var frameRates: [Int: Int] = [:]

    public init(
        title: String, url: URL, entries: [Entry], total: Int?, isMusic: Bool, isCut: Bool = false, channel: String? = nil, thumbnail: URL? = nil,
        updated: Date? = nil, heights: [Int]? = nil
    ) {
        self.heights = heights
        self.channel = channel
        self.thumbnail = thumbnail
        self.updated = updated
        self.title = title
        self.url = url
        self.entries = entries
        self.total = total
        self.isMusic = isMusic
        self.isCut = isCut
    }
    public var available: [Entry] { entries.filter(\.isAvailable) }
}
