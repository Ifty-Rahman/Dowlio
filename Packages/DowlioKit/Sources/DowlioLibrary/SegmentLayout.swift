import DowlioCore

/// The segments a download started with, kept for the download list's bar. Work stealing splits a
/// segment under the hood; the bar still shows one piece, filled by every part inside it.
public enum SegmentLayout {
    public static func bounds(of segments: [SegmentProgress]) -> [SegmentBounds] {
        segments.map { SegmentBounds(start: $0.start, end: $0.end) }
    }

    /// Stealing only splits segments, so each original piece still starts a segment and the file
    /// still ends in the same place. Anything else, such as starting over with a new layout, means
    /// the original layout no longer applies.
    public static func stillMatches(planned: [SegmentBounds], current: [SegmentProgress]) -> Bool {
        guard !planned.isEmpty, !current.isEmpty else { return false }
        let starts = Set(current.map(\.start))
        return planned.allSatisfy { starts.contains($0.start) }
            && current.map(\.end).max() == planned.map(\.end).max()
            && current.map(\.start).min() == planned.map(\.start).min()
    }

    public static func shown(planned: [SegmentBounds], current: [SegmentProgress]) -> [SegmentProgress] {
        guard !current.isEmpty else { return [] }
        guard stillMatches(planned: planned, current: current) else { return current }
        return planned.map { piece in
            let inside = current.filter { $0.start >= piece.start && $0.start <= piece.end }
            let received = inside.reduce(Int64(0)) { total, part in
                let lastReceived = part.start + part.receivedBytes - 1
                return total + max(min(lastReceived, piece.end) - part.start + 1, 0)
            }
            return SegmentProgress(start: piece.start, end: piece.end, receivedBytes: received, isActive: inside.contains(where: \.isActive))
        }
    }
}
