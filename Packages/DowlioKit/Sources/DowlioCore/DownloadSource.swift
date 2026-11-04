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
    /// The finished file's container. `nil` takes MP4, or M4A for audio.
    public let container: MediaContainer?
    /// When the tracks' links stop working, for links that say so.
    public let expiry: Date?
    /// How to get fresh links for the same formats once these expire.
    public let renewal: MediaRenewal?

    public init(
        tracks: [MediaTrack], keepsAudioOnly: Bool = false, container: MediaContainer? = nil, expiry: Date? = nil,
        renewal: MediaRenewal? = nil
    ) throws {
        guard !tracks.isEmpty else { throw Error.noTracks }
        guard tracks.allSatisfy({ !$0.fragments.isEmpty }) else { throw Error.trackWithoutFragments }
        self.tracks = tracks
        self.keepsAudioOnly = keepsAudioOnly
        self.container = container
        self.expiry = expiry
        self.renewal = renewal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tracks: container.decode([MediaTrack].self, forKey: .tracks),
            keepsAudioOnly: container.decodeIfPresent(Bool.self, forKey: .keepsAudioOnly) ?? false,
            container: container.decodeIfPresent(MediaContainer.self, forKey: .container),
            expiry: container.decodeIfPresent(Date.self, forKey: .expiry),
            renewal: container.decodeIfPresent(MediaRenewal.self, forKey: .renewal)
        )
    }

    public var isAudio: Bool {
        keepsAudioOnly || tracks.allSatisfy { $0.kind == .audio }
    }

    public var outputContainer: MediaContainer { container ?? (isAudio ? .m4a : .mp4) }

    public var fileExtension: String { outputContainer.rawValue }

    public var contentType: String { outputContainer.contentType }

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

    public var contentType: String {
        switch self {
        case .mp4: "video/mp4"
        case .m4a: "audio/mp4"
        case .webm: "video/webm"
        }
    }
}

public struct MediaRenewal: Codable, Equatable, Sendable {
    /// The page yt-dlp read the formats from.
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

    public init(kind: Kind, initialization: MediaFragment? = nil, fragments: [MediaFragment]) {
        self.kind = kind
        self.initialization = initialization
        self.fragments = fragments
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

/// The downloaded tracks of a media download, and the one file they become.
public struct RemuxRequest: Sendable {
    public var tracks: [URL]
    public var output: URL
    public var media: MediaSource

    public init(tracks: [URL], output: URL, media: MediaSource) {
        self.tracks = tracks
        self.output = output
        self.media = media
    }
}
