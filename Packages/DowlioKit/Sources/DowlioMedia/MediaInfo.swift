import Foundation

public struct MediaInfo: Decodable, Equatable, Sendable {
    public struct Format: Decodable, Equatable, Sendable {
        public var id: String
        public var height: Int?
        public var frameRate: Double?
        public var videoCodec: String?
        public var audioCodec: String?
        public var fileExtension: String?
        public var dynamicRange: String?
        public var language: String?
        public var languagePreference: Int?
        public var note: String?
        public var audioChannels: Int?
        public var size: Int64?
        public var estimatedSize: Int64?
        public var bitrate: Double?
        public var `protocol`: String?
        public var url: URL?
        public var headers: [String: String]
        public var requestSizeLimit: Int64?
        public var fragmentURLs: [URL]
        private var videoCodecIsNone = false
        private var audioCodecIsNone = false

        enum CodingKeys: String, CodingKey {
            case id = "format_id"
            case height
            case frameRate = "fps"
            case videoCodec = "vcodec"
            case audioCodec = "acodec"
            case fileExtension = "ext"
            case dynamicRange = "dynamic_range"
            case language
            case languagePreference = "language_preference"
            case note = "format_note"
            case audioChannels = "audio_channels"
            case size = "filesize"
            case estimatedSize = "filesize_approx"
            case bitrate = "tbr"
            case `protocol`
            case url
            case headers = "http_headers"
            case downloaderOptions = "downloader_options"
            case fragments
            case fragmentBaseURL = "fragment_base_url"
        }

        private struct Fragment: Decodable {
            var url: String?
            var path: String?
        }

        private struct DownloaderOptions: Decodable {
            var chunkSize: Int64?

            enum CodingKeys: String, CodingKey {
                case chunkSize = "http_chunk_size"
            }
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            url = (try? values.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
            height = try? values.decodeIfPresent(Int.self, forKey: .height)
            frameRate = try? values.decodeIfPresent(Double.self, forKey: .frameRate)
            let video = try? values.decodeIfPresent(String.self, forKey: .videoCodec)
            let audio = try? values.decodeIfPresent(String.self, forKey: .audioCodec)
            videoCodec = Self.codec(video)
            audioCodec = Self.codec(audio)
            videoCodecIsNone = video == "none"
            audioCodecIsNone = audio == "none"
            fileExtension = try? values.decodeIfPresent(String.self, forKey: .fileExtension)
            dynamicRange = try? values.decodeIfPresent(String.self, forKey: .dynamicRange)
            language = try? values.decodeIfPresent(String.self, forKey: .language)
            languagePreference = try? values.decodeIfPresent(Int.self, forKey: .languagePreference)
            note = try? values.decodeIfPresent(String.self, forKey: .note)
            audioChannels = try? values.decodeIfPresent(Int.self, forKey: .audioChannels)
            size = Self.bytes(values, .size) ?? Self.contentLength(in: url)
            estimatedSize = Self.bytes(values, .estimatedSize)
            bitrate = try? values.decodeIfPresent(Double.self, forKey: .bitrate)
            `protocol` = try? values.decodeIfPresent(String.self, forKey: .protocol)
            headers = ((try? values.decodeIfPresent([String: Lenient<String>].self, forKey: .headers)) ?? [:]).compactMapValues(\.value)
            requestSizeLimit = (try? values.decodeIfPresent(DownloaderOptions.self, forKey: .downloaderOptions))?.chunkSize
            let base = (try? values.decodeIfPresent(String.self, forKey: .fragmentBaseURL)).flatMap(URL.init(string:))
            let fragments = ((try? values.decodeIfPresent([Lenient<Fragment>].self, forKey: .fragments)) ?? []).compactMap(\.value)
            fragmentURLs = fragments.compactMap { fragment in
                if let url = fragment.url { return URL(string: url) }
                guard let path = fragment.path else { return nil }
                return base.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL } ?? URL(string: path)
            }
        }

        private static func codec(_ value: String?) -> String? {
            guard let value, value != "none", !value.isEmpty else { return nil }
            return value
        }

        private static func bytes(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
            if let whole = try? values.decodeIfPresent(Int64.self, forKey: key) { return whole }
            return (try? values.decodeIfPresent(Double.self, forKey: key)).map { Int64($0) }
        }

        private static func contentLength(in url: URL?) -> Int64? {
            guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            return items.first { $0.name == "clen" }?.value.flatMap { Int64($0) }
        }

        static let originalTrackPreference = 10

        private static let videoExtensions: Set<String> = ["mp4", "m4v", "webm", "mov", "mkv", "flv", "ogv", "avi", "3gp"]
        private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "flac", "wav"]

        private var codecsUnknown: Bool { videoCodec == nil && audioCodec == nil && !videoCodecIsNone && !audioCodecIsNone }

        private static let imageExtensions: Set<String> = ["mhtml", "jpg", "jpeg", "png", "webp", "gif"]

        public var hasVideo: Bool {
            if videoCodec != nil { return true }
            if videoCodecIsNone || Self.imageExtensions.contains(fileExtension ?? "") { return false }
            if audioCodecIsNone { return true }
            guard codecsUnknown else { return false }
            return height != nil || Self.videoExtensions.contains(fileExtension ?? "")
        }

        public var hasAudio: Bool {
            if audioCodec != nil { return true }
            if audioCodecIsNone || Self.imageExtensions.contains(fileExtension ?? "") { return false }
            if videoCodecIsNone { return true }
            guard codecsUnknown else { return false }
            return hasVideo || Self.audioExtensions.contains(fileExtension ?? "")
        }

        public var mayBeAAC: Bool {
            guard let codec = audioCodec else { return ["mp4", "m4a"].contains(fileExtension ?? "") }
            return MediaCodecs.isAAC(codec)
        }

        public var isOriginalAudio: Bool {
            languagePreference == Self.originalTrackPreference || (note?.lowercased().contains("original") ?? false)
        }

        public var expiry: Date? {
            guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let value = items.first(where: { $0.name == "expire" })?.value, let seconds = TimeInterval(value) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    public struct TextTrack: Decodable, Equatable, Sendable {
        public var ext: String?
        public var url: URL?
        public var name: String?

        enum CodingKeys: String, CodingKey { case ext, url, name }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            ext = try? values.decodeIfPresent(String.self, forKey: .ext)
            url = (try? values.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
            name = try? values.decodeIfPresent(String.self, forKey: .name)
        }

        public var isTranslation: Bool { url?.query()?.contains("tlang=") ?? false }
    }

    public struct Chapter: Decodable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var title: String

        enum CodingKeys: String, CodingKey {
            case title
            case start = "start_time"
            case end = "end_time"
        }
    }

    public var title: String?
    public var thumbnail: URL?
    public var duration: Double?
    public var liveStatus: String?
    public var webpageURL: URL?
    public var formats: [Format]
    public var subtitles: [String: [TextTrack]]
    public var automaticCaptions: [String: [TextTrack]]
    public var chapters: [Chapter]
    public var thumbnails: [Thumbnail]
    public var type: String?
    public var entries: [Entry]
    public var playlistCount: Int?
    public var channel: String?
    public var modifiedDate: String?

    public struct Entry: Decodable, Equatable, Sendable {
        public var id: String?
        public var url: URL?
        public var title: String?
        public var duration: Double?
        public var availability: String?
        public var thumbnails: [Thumbnail]

        enum CodingKeys: String, CodingKey { case id, url, title, duration, availability, thumbnails }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try? values.decodeIfPresent(String.self, forKey: .id)
            url = (try? values.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
            title = try? values.decodeIfPresent(String.self, forKey: .title)
            duration = try? values.decodeIfPresent(Double.self, forKey: .duration)
            availability = try? values.decodeIfPresent(String.self, forKey: .availability)
            thumbnails = ((try? values.decodeIfPresent([Lenient<Thumbnail>].self, forKey: .thumbnails)) ?? []).compactMap(\.value)
        }

        public var thumbnail: URL? { MediaInfo.widest(thumbnails) }

        public var isAvailable: Bool {
            if ["private", "needs_auth", "subscriber_only", "premium_only"].contains(availability ?? "") { return false }
            return !["[Private video]", "[Deleted video]"].contains(title ?? "")
        }
    }

    public struct Thumbnail: Decodable, Equatable, Sendable {
        public var url: URL
        public var preference: Int?
        public var width: Int?

        enum CodingKeys: String, CodingKey { case url, preference, width }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let url = URL(string: try values.decode(String.self, forKey: .url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "not a URL")
            }
            self.url = url
            preference = try? values.decodeIfPresent(Int.self, forKey: .preference)
            width = try? values.decodeIfPresent(Int.self, forKey: .width)
        }
    }

    public var coverArt: URL? {
        if let thumbnail, Self.isStill(thumbnail) { return thumbnail }
        if let thumbnail, let jpeg = Self.youTubeJPEG(for: thumbnail) { return jpeg }
        let stills = thumbnails.filter { Self.isStill($0.url) }.sorted { ($0.preference ?? 0, $0.width ?? 0) > ($1.preference ?? 0, $1.width ?? 0) }
        return stills.first?.url
    }

    public var playlistThumbnail: URL? { Self.widest(thumbnails) }

    static func widest(_ thumbnails: [Thumbnail]) -> URL? {
        thumbnails.filter { isStill($0.url) }.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
    }

    private static func isStill(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased())
    }

    private static func youTubeJPEG(for url: URL) -> URL? {
        guard let host = url.host(percentEncoded: false)?.lowercased(), host == "ytimg.com" || host.hasSuffix(".ytimg.com"),
              url.pathExtension.lowercased() == "webp",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/vi_webp/", with: "/vi/")
        components.path = String(components.path.dropLast("webp".count)) + "jpg"
        components.query = nil
        return components.url
    }

    public var isLiveNow: Bool { liveStatus == "is_live" || liveStatus == "is_upcoming" }

    enum CodingKeys: String, CodingKey {
        case title, thumbnail, duration, formats, subtitles, chapters, thumbnails, entries
        case type = "_type"
        case playlistCount = "playlist_count"
        case channel, uploader
        case modifiedDate = "modified_date"
        case liveStatus = "live_status"
        case webpageURL = "webpage_url"
        case automaticCaptions = "automatic_captions"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        thumbnail = (try? values.decodeIfPresent(String.self, forKey: .thumbnail)).flatMap(URL.init(string:))
        duration = try? values.decodeIfPresent(Double.self, forKey: .duration)
        liveStatus = try? values.decodeIfPresent(String.self, forKey: .liveStatus)
        webpageURL = (try? values.decodeIfPresent(String.self, forKey: .webpageURL)).flatMap(URL.init(string:))
        formats = ((try? values.decodeIfPresent([Lenient<Format>].self, forKey: .formats)) ?? []).compactMap(\.value)
        subtitles = (try? values.decodeIfPresent([String: [TextTrack]].self, forKey: .subtitles)) ?? [:]
        automaticCaptions = (try? values.decodeIfPresent([String: [TextTrack]].self, forKey: .automaticCaptions)) ?? [:]
        chapters = ((try? values.decodeIfPresent([Lenient<Chapter>].self, forKey: .chapters)) ?? []).compactMap(\.value)
        thumbnails = ((try? values.decodeIfPresent([Lenient<Thumbnail>].self, forKey: .thumbnails)) ?? []).compactMap(\.value)
        type = try? values.decodeIfPresent(String.self, forKey: .type)
        entries = ((try? values.decodeIfPresent([Lenient<Entry>].self, forKey: .entries)) ?? []).compactMap(\.value)
        playlistCount = try? values.decodeIfPresent(Int.self, forKey: .playlistCount)
        channel = (try? values.decodeIfPresent(String.self, forKey: .channel)) ?? (try? values.decodeIfPresent(String.self, forKey: .uploader))
        modifiedDate = try? values.decodeIfPresent(String.self, forKey: .modifiedDate)
    }
}

struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
