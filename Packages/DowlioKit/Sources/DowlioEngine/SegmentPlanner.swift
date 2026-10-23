/// Splits a file into segments. Pure logic: no I/O and no clock (spec, segment planner).
enum SegmentPlanner {
    /// No segment is ever smaller than this.
    static let minimumSegmentSize: Int64 = 1_048_576
    /// The most connections one download may use.
    static let maximumConnections = 16

    /// Contiguous segments that cover `size` bytes exactly. Their count is the smallest of the
    /// connection setting (clamped to 1...16) and the number of 1 MiB segments the file can
    /// hold, and never below 1.
    static func plan(size: Int64, connections: Int) -> [ByteRange] {
        guard size > 0 else { return [] }
        let allowed = Int64(min(max(connections, 1), maximumConnections))
        let count = max(1, min(allowed, size / minimumSegmentSize))
        return (0..<count).map { index in
            ByteRange(start: size * index / count, end: size * (index + 1) / count - 1)
        }
    }
}
