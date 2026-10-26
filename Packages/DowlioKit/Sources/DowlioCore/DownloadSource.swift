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

    public init(tracks: [MediaTrack], keepsAudioOnly: Bool = false) throws {
        guard !tracks.isEmpty else { throw Error.noTracks }
        guard tracks.allSatisfy({ !$0.fragments.isEmpty }) else { throw Error.trackWithoutFragments }
        self.tracks = tracks
        self.keepsAudioOnly = keepsAudioOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tracks: container.decode([MediaTrack].self, forKey: .tracks),
            keepsAudioOnly: container.decodeIfPresent(Bool.self, forKey: .keepsAudioOnly) ?? false
        )
    }

    public var isAudio: Bool {
        keepsAudioOnly || tracks.allSatisfy { $0.kind == .audio }
    }

    public var fileExtension: String { isAudio ? "m4a" : "mp4" }

    public var contentType: String { isAudio ? "audio/mp4" : "video/mp4" }

    public var extractsAudio: Bool {
        keepsAudioOnly && tracks.contains { $0.kind != .audio }
    }

    public var firstURL: URL {
        tracks[0].fragments[0].url
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

    public init(url: URL, bytes: ClosedRange<Int64>? = nil) {
        self.url = url
        self.bytes = bytes
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
