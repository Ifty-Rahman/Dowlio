enum SegmentPlanner {
    static let minimumSegmentSize: Int64 = 122_880
    /// The most connections one download may use.
    static let maximumConnections = 16
    static let maximumSegments = 32

    static func connectionsWorthOpening(missing: Int64, wanted: Int) -> Int {
        max(0, min(wanted, Int(missing / (2 * minimumSegmentSize))))
    }

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
