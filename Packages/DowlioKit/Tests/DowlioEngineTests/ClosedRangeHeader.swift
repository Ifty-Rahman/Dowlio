import DowlioCore

struct ClosedRangeHeader: Equatable {
    let start: Int64
    let end: Int64

    init?(_ value: String) {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        self.start = start
        self.end = end
    }

    static func eachMissingPartIsAskedFromItsStart(_ segments: [SegmentProgress], asked: [ClosedRangeHeader]) -> Bool {
        segments.filter { $0.start + $0.receivedBytes <= $0.end }.allSatisfy { segment in
            asked.contains { $0.start == segment.start + segment.receivedBytes && $0.end <= segment.end }
        }
    }

    static func noneAsksForReceivedBytes(_ segments: [SegmentProgress], asked: [ClosedRangeHeader]) -> Bool {
        asked.allSatisfy { range in
            segments.allSatisfy { segment in
                let received = segment.receivedBytes > 0 ? segment.start...(segment.start + segment.receivedBytes - 1) : nil
                return received.map { !$0.overlaps(range.start...range.end) } ?? true
            }
        }
    }
}
