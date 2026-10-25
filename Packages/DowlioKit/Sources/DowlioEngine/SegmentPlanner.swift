/// Splits a file into segments the way Neat Download Manager does: a download starts as one
/// segment, and each new connection splits the largest part no connection has reached yet. Pure
/// logic: no I/O and no clock.
enum SegmentPlanner {
    /// No split leaves a half smaller than this. Neat's smallest halves measured 120 KiB.
    static let minimumSegmentSize: Int64 = 122_880
    /// The most connections one download may use.
    static let maximumConnections = 16
    /// The most segments splitting may make, counting the first.
    static let maximumSegments = 32

    /// How many more connections the ramp-up opens: the `wanted` ones, but no more than one per
    /// 240 KiB the download still misses. Measured on Neat: 1 MiB opens 6 connections, 512 KiB 4,
    /// 256 KiB 2, 128 KiB 1, and 2 MiB or more all 8.
    static func connectionsWorthOpening(missing: Int64, wanted: Int) -> Int {
        max(0, min(wanted, Int(missing / (2 * minimumSegmentSize))))
    }

    /// The one segment a download with ranges starts with.
    static func firstSegment(size: Int64) -> [ByteRange] {
        size > 0 ? [ByteRange(start: 0, end: size - 1)] : []
    }

    /// How a free connection takes over work: `victim` keeps `kept`, and the connection fetches
    /// `taken`, which ends where the victim's range ended.
    struct Steal: Equatable {
        let victim: Int
        let kept: ByteRange
        let taken: ByteRange
    }

    /// The split for a new connection, or for one that finished its segment. `remaining` holds
    /// each segment's part that isn't downloaded yet, or `nil` when the segment is finished. The
    /// connection takes the second half of the largest remaining range, the first on a tie, and
    /// only when both halves stay at 120 KiB or more, and while the download has fewer than 32
    /// segments. `nil` means nothing can be split, so the connection closes.
    static func steal(from remaining: [ByteRange?]) -> Steal? {
        guard remaining.count < maximumSegments else { return nil }
        var largest: (index: Int, range: ByteRange)?
        for (index, range) in remaining.enumerated() {
            guard let range else { continue }
            if range.length > largest?.range.length ?? 0 { largest = (index, range) }
        }
        guard let (victim, range) = largest, range.length / 2 >= minimumSegmentSize else { return nil }
        // The kept half takes the extra byte of an odd length.
        let keptLength = range.length - range.length / 2
        return Steal(
            victim: victim,
            kept: ByteRange(start: range.start, end: range.start + keptLength - 1),
            taken: ByteRange(start: range.start + keptLength, end: range.end)
        )
    }

    /// A host's connection limit after it refused a connection with 429, 503 or a reset: one
    /// fewer, never below 1.
    static func lowered(_ limit: Int) -> Int {
        max(1, limit - 1)
    }
}
