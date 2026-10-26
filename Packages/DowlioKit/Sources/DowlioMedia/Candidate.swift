import DowlioCore
import Foundation

public struct SentPage: Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var browser: String?
    public var cookies: [Cookie]
    public var userAgent: String?
    public var scan: [ScannedMedia]
    public var embeddedJSON: [String]

    public init(
        url: URL,
        title: String? = nil,
        browser: String? = nil,
        cookies: [Cookie] = [],
        userAgent: String? = nil,
        scan: [ScannedMedia] = [],
        embeddedJSON: [String] = []
    ) {
        self.url = url
        self.title = title
        self.browser = browser
        self.cookies = cookies
        self.userAgent = userAgent
        self.scan = scan
        self.embeddedJSON = embeddedJSON
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

    public init(url: URL, kind: Kind, poster: URL? = nil, duration: Double? = nil, group: Int? = nil) {
        self.url = url
        self.kind = kind
        self.poster = poster
        self.duration = duration
        self.group = group
    }
}

public struct Candidate: Equatable, Sendable {
    public var label: String
    public var thumbnail: URL?
    public var duration: Double?
    public var versions: [Version]

    public init(label: String, thumbnail: URL? = nil, duration: Double? = nil, versions: [Version]) {
        self.label = label
        self.thumbnail = thumbnail
        self.duration = duration
        self.versions = versions
    }
}

public struct Version: Equatable, Sendable {
    public var source: DownloadSource
    public var contentType: String?
    public var totalBytes: Int64?

    public init(source: DownloadSource, contentType: String? = nil, totalBytes: Int64? = nil) {
        self.source = source
        self.contentType = contentType
        self.totalBytes = totalBytes
    }
}

public enum PageAnalysis: Equatable, Sendable {
    case looking([Candidate])
    case plainFile(URL)
    case found([Candidate])
}
