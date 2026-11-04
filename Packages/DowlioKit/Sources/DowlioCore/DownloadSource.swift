import Foundation

public enum DownloadSource: Equatable, Sendable {
    case file(URL)
    case media(MediaSource)

    public var url: URL {
        switch self {
        case .file(let url): url
        case .media(let media): media.firstURL
        }
    }
}

public struct MediaSource: Codable, Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case noTracks
        case trackWithoutFragments
    }

    public let tracks: [MediaTrack]
    public let keepsAudioOnly: Bool
    public let container: MediaContainer?
    public let expiry: Date?
    public let renewal: MediaRenewal?
    public let downloadsWithYTDLP: Bool
    public let extras: MediaExtras?

    public init(
        tracks: [MediaTrack], keepsAudioOnly: Bool = false, container: MediaContainer? = nil, expiry: Date? = nil,
        renewal: MediaRenewal? = nil, downloadsWithYTDLP: Bool = false, extras: MediaExtras? = nil
    ) throws {
        self.extras = extras?.isEmpty == true ? nil : extras
        guard !tracks.isEmpty else { throw Error.noTracks }
        guard tracks.allSatisfy({ !$0.fragments.isEmpty }) else { throw Error.trackWithoutFragments }
        self.tracks = tracks
        self.keepsAudioOnly = keepsAudioOnly
        self.container = container
        self.expiry = expiry
        self.renewal = renewal
        self.downloadsWithYTDLP = downloadsWithYTDLP
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tracks: values.decode([MediaTrack].self, forKey: .tracks),
            keepsAudioOnly: values.decodeIfPresent(Bool.self, forKey: .keepsAudioOnly) ?? false,
            container: values.decodeIfPresent(MediaContainer.self, forKey: .container),
            expiry: values.decodeIfPresent(Date.self, forKey: .expiry),
            renewal: values.decodeIfPresent(MediaRenewal.self, forKey: .renewal),
            downloadsWithYTDLP: values.decodeIfPresent(Bool.self, forKey: .downloadsWithYTDLP) ?? false,
            extras: values.decodeIfPresent(MediaExtras.self, forKey: .extras)
        )
    }

    public var isAudio: Bool {
        keepsAudioOnly || tracks.allSatisfy { $0.kind == .audio }
    }

    public func with(extras: MediaExtras?) -> MediaSource {
        (try? MediaSource(
            tracks: tracks, keepsAudioOnly: keepsAudioOnly, container: container, expiry: expiry, renewal: renewal,
            downloadsWithYTDLP: downloadsWithYTDLP, extras: extras
        )) ?? self
    }

    public var outputContainer: MediaContainer { container ?? (isAudio ? .m4a : .mp4) }

    public var fileExtension: String { outputContainer.rawValue }

    public var contentType: String { outputContainer.contentType(isAudio: isAudio) }

    public var extractsAudio: Bool {
        keepsAudioOnly && tracks.contains { $0.kind != .audio }
    }

    public var firstURL: URL {
        tracks[0].fragments[0].url
    }
}

public enum MediaContainer: String, Codable, Sendable {
    case mp4
    case m4a
    case webm

    public var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .m4a: "M4A"
        case .webm: "WebM"
        }
    }

    public func contentType(isAudio: Bool) -> String {
        switch self {
        case .mp4: "video/mp4"
        case .m4a: "audio/mp4"
        case .webm: isAudio ? "audio/webm" : "video/webm"
        }
    }
}

public struct MediaExtras: Codable, Equatable, Sendable {
    public struct Subtitle: Codable, Equatable, Sendable {
        public var language: String
        public var name: String
        public var url: URL
        public var format: String

        public init(language: String, name: String, url: URL, format: String) {
            self.language = language
            self.name = name
            self.url = url
            self.format = format
        }
    }

    public struct Chapter: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var title: String

        public init(start: Double, end: Double, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    public var subtitles: [Subtitle]
    public var chapters: [Chapter]
    public var coverArt: URL?

    public init(subtitles: [Subtitle] = [], chapters: [Chapter] = [], coverArt: URL? = nil) {
        self.subtitles = subtitles
        self.chapters = chapters
        self.coverArt = coverArt
    }

    public var isEmpty: Bool { subtitles.isEmpty && chapters.isEmpty && coverArt == nil }
}

public struct MediaRenewal: Codable, Equatable, Sendable {
    public var pageURL: URL
    public var formatIDs: [String]

    public init(pageURL: URL, formatIDs: [String]) {
        self.pageURL = pageURL
        self.formatIDs = formatIDs
    }
}

public struct MediaTrack: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
        case audio
        case combined
    }

    public var kind: Kind
    public var initialization: MediaFragment?
    public var fragments: [MediaFragment]
    public var codecs: [String]?

    public init(kind: Kind, initialization: MediaFragment? = nil, fragments: [MediaFragment], codecs: [String]? = nil) {
        self.kind = kind
        self.initialization = initialization
        self.fragments = fragments
        self.codecs = codecs
    }
}

public struct MediaFragment: Codable, Equatable, Sendable {
    public var url: URL
    public var bytes: ClosedRange<Int64>?
    public var key: FragmentKey?

    public init(url: URL, bytes: ClosedRange<Int64>? = nil, key: FragmentKey? = nil) {
        self.url = url
        self.bytes = bytes
        self.key = key
    }
}

public struct FragmentKey: Codable, Hashable, Sendable {
    public var url: URL
    public var iv: Data

    public init(url: URL, iv: Data) {
        self.url = url
        self.iv = iv
    }
}

public struct FragmentPosition: Codable, Hashable, Sendable {
    public var track: Int
    public var fragment: Int

    public init(track: Int, fragment: Int) {
        self.track = track
        self.fragment = fragment
    }
}

public struct YTDLPProgress: Equatable, Sendable {
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Int64
    public var secondsLeft: TimeInterval?

    public init(receivedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Int64, secondsLeft: TimeInterval?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.secondsLeft = secondsLeft
    }
}

public struct YTDLPDownload: Sendable {
    public var media: MediaSource
    public var folder: URL
    public var progress: @Sendable (YTDLPProgress) -> Void

    public init(media: MediaSource, folder: URL, progress: @escaping @Sendable (YTDLPProgress) -> Void) {
        self.media = media
        self.folder = folder
        self.progress = progress
    }
}

public struct RemuxRequest: Sendable {
    public struct SubtitleFile: Equatable, Sendable {
        public var file: URL
        public var language: String
        public var name: String

        public init(file: URL, language: String, name: String) {
            self.file = file
            self.language = language
            self.name = name
        }
    }

    public var tracks: [URL]
    public var output: URL
    public var mediaSource: MediaSource
    public var subtitles: [SubtitleFile]
    public var chapters: [MediaExtras.Chapter]
    public var coverArt: URL?

    public init(
        tracks: [URL], output: URL, mediaSource: MediaSource, subtitles: [SubtitleFile] = [], chapters: [MediaExtras.Chapter] = [],
        coverArt: URL? = nil
    ) {
        self.tracks = tracks
        self.output = output
        self.mediaSource = mediaSource
        self.subtitles = subtitles
        self.chapters = chapters
        self.coverArt = coverArt
    }

    public var hasExtras: Bool { !subtitles.isEmpty || !chapters.isEmpty || coverArt != nil }
}
