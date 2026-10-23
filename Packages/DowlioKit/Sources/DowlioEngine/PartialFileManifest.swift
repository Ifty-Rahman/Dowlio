import Foundation

/// The `manifest.json` inside a partial file: everything needed to resume the download, so the
/// partial file is self-contained (architecture.md, files on disk). It never holds cookies.
struct PartialFileManifest: Codable, Equatable, Sendable {
    /// Format 2 added `layout`.
    static let currentFormatVersion = 2
    /// The oldest format this version still reads.
    static let oldestReadableFormatVersion = 1

    struct Segment: Codable, Equatable, Sendable {
        var start: Int64
        /// Inclusive.
        var end: Int64
        /// Bytes from `start` that are in the data file. May lag the data file, never lead it.
        var received: Int64
    }

    var formatVersion: Int
    var downloadID: String
    var originalURL: URL
    var finalURL: URL
    /// The strong `ETag` or `Last-Modified` that segment requests send as `If-Range`.
    var validator: String?
    var totalBytes: Int64?
    /// The name the finished file will have.
    var fileName: String
    var connections: Int
    var referrer: URL?
    var userAgent: String?
    var segments: [Segment]
    /// Whether the server supports ranges. `nil` in a format 1 manifest, which didn't record it,
    /// so the download is read as whole and starts over on resume.
    var layout: Layout?

    enum Layout: String, Codable, Sendable {
        /// One connection reads the whole file, so a resume starts over.
        case whole
        /// The server supports ranges, so segments can continue.
        case ranges
    }
}
