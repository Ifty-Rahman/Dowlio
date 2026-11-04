import Foundation

public struct MediaInfo: Decodable, Equatable, Sendable {
    public var title: String?
    public var thumbnail: URL?
    public var duration: Double?
    public var liveStatus: String?
    public var webpageURL: URL?

    enum CodingKeys: String, CodingKey {
        case title, thumbnail, duration
        case liveStatus = "live_status"
        case webpageURL = "webpage_url"
    }
}
