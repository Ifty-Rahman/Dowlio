import DowlioCore
import Foundation

/// The `manifest.json` inside a partial file: everything needed to resume the download, so the
/// partial file is self-contained (architecture.md, files on disk). It never holds cookies.
struct PartialFileManifest: Codable, Equatable, Sendable {
    /// Format 2 added `layout`, format 3 `nameConflictPolicy`.
    static let currentFormatVersion = 3
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
    /// `nil` before format 3, which added it, and read as keep both.
    var nameConflictPolicy: NameConflictPolicy?

    /// Whether every segment lies inside the file, after the one before it, and holds no more
    /// bytes than its own length. A manifest without a size has no segments.
    var segmentsFitTheFile: Bool {
        guard let totalBytes else { return segments.isEmpty }
        var next: Int64 = 0
        for segment in segments {
            guard segment.start >= next, segment.start <= segment.end, segment.end < totalBytes,
                  (0...(segment.end - segment.start + 1)).contains(segment.received) else { return false }
            next = segment.end + 1
        }
        return true
    }

    enum Layout: String, Codable, Sendable {
        /// One connection reads the whole file, so a resume starts over.
        case whole
        /// The server supports ranges, so segments can continue.
        case ranges
    }
}
