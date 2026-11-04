import Foundation

public struct MediaInfo: Decodable, Equatable, Sendable {
    public struct Format: Decodable, Equatable, Sendable {
        public var id: String
        public var height: Int?
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

        enum CodingKeys: String, CodingKey {
            case id = "format_id"
            case height
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
            videoCodec = Self.codec(try? values.decodeIfPresent(String.self, forKey: .videoCodec))
            audioCodec = Self.codec(try? values.decodeIfPresent(String.self, forKey: .audioCodec))
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

        public var hasVideo: Bool { videoCodec != nil }
        public var hasAudio: Bool { audioCodec != nil }

        public var isOriginalAudio: Bool {
            languagePreference == Self.originalTrackPreference || (note?.lowercased().contains("original") ?? false)
        }

        public var expiry: Date? {
            guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let value = items.first(where: { $0.name == "expire" })?.value, let seconds = TimeInterval(value) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    public var title: String?
    public var thumbnail: URL?
    public var duration: Double?
    public var liveStatus: String?
    public var webpageURL: URL?
    public var formats: [Format]

    public var isLiveNow: Bool { liveStatus == "is_live" || liveStatus == "is_upcoming" }

    enum CodingKeys: String, CodingKey {
        case title, thumbnail, duration, formats
        case liveStatus = "live_status"
        case webpageURL = "webpage_url"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        thumbnail = (try? values.decodeIfPresent(String.self, forKey: .thumbnail)).flatMap(URL.init(string:))
        duration = try? values.decodeIfPresent(Double.self, forKey: .duration)
        liveStatus = try? values.decodeIfPresent(String.self, forKey: .liveStatus)
        webpageURL = (try? values.decodeIfPresent(String.self, forKey: .webpageURL)).flatMap(URL.init(string:))
        formats = ((try? values.decodeIfPresent([Lenient<Format>].self, forKey: .formats)) ?? []).compactMap(\.value)
    }
}

struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
