/// Splits a file into segments. Pure logic: no I/O and no clock.
enum SegmentPlanner {
    /// No segment is ever smaller than this.
    static let minimumSegmentSize: Int64 = 1_048_576
    /// The most connections one download may use.
    static let maximumConnections = 16

    /// Contiguous segments that cover `size` bytes exactly. Their count is the smallest of the
    /// connection setting (clamped to 1...16), the host's learned limit, and the number of 1 MiB
    /// segments the file can hold, and never below 1.
    static func plan(size: Int64, connections: Int, hostLimit: Int? = nil) -> [ByteRange] {
        guard size > 0 else { return [] }
        let allowed = Int64(min(max(min(connections, hostLimit ?? .max), 1), maximumConnections))
        let count = max(1, min(allowed, size / minimumSegmentSize))
        return (0..<count).map { index in
            ByteRange(start: size * index / count, end: size * (index + 1) / count - 1)
        }
    }

    /// How a free connection takes over work: `victim` keeps `kept`, and the connection fetches
    /// `taken`, which ends where the victim's range ended.
    struct Steal: Equatable {
        let victim: Int
        let kept: ByteRange
        let taken: ByteRange
    }

    /// The steal for a connection that finished its segment. `remaining` holds each segment's part
    /// that isn't downloaded yet, or `nil` when the segment is finished. The connection takes the
    /// second half of the largest remaining range, the first on a tie, and only when both halves
    /// stay at 1 MiB or more. `nil` means nothing can be stolen, so the connection closes.
    static func steal(from remaining: [ByteRange?]) -> Steal? {
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
