import DowlioCore
import Foundation

/// Each segment's progress, shared between a download's connections and its progress reporter.
final class ProgressBoard: @unchecked Sendable {
    // @unchecked: every stored property is only read or written under `lock`.

    struct Reading: Equatable {
        var segments: [SegmentProgress]
        var receivedBytes: Int64
        var activeConnections: Int
    }

    private let lock = NSLock()
    /// Indexes stay stable while a download runs. Stealing appends new segments at the end.
    private var segments: [SegmentProgress]
    /// Bytes of a download whose size is unknown, so it has no segments.
    private var unsegmentedBytes: Int64 = 0
    /// Per segment, the bytes from its start a connection has taken on: written, or about to be.
    /// Never below `receivedBytes`. Stealing never takes these bytes.
    private var claimed: [Int64]
    private var rolledBack: [Bool]
    private var shownStarts: Set<Int64>
    let drawsRampUp: Bool

    init(segments: [ByteRange]) {
        self.segments = segments.map { SegmentProgress(start: $0.start, end: $0.end) }
        claimed = Array(repeating: 0, count: segments.count)
        rolledBack = Array(repeating: false, count: segments.count)
        shownStarts = Set(segments.map(\.start))
        drawsRampUp = segments.count <= 1
    }

    /// A board for segments that already hold `received` bytes each, from a restored manifest.
    convenience init(segments: [ByteRange], received: [Int64]) {
        self.init(segments: segments)
        for (index, count) in received.enumerated() { add(count, to: index) }
    }

    /// Adds `bytes` to segment `index`, or to the unsegmented count when the size is unknown.
    func add(_ bytes: Int64, to index: Int?) {
        lock.withLock {
            if let index {
                segments[index].receivedBytes += bytes
                claimed[index] = max(claimed[index], segments[index].receivedBytes)
            } else {
                unsegmentedBytes += bytes
            }
        }
    }

    /// Forgets every byte received, for a download that starts over.
    func reset() {
        lock.withLock {
            for index in segments.indices { segments[index].receivedBytes = 0 }
            claimed = Array(repeating: 0, count: segments.count)
            unsegmentedBytes = 0
        }
    }

    func setActive(_ isActive: Bool, segment index: Int) {
        lock.withLock { segments[index].isActive = isActive }
    }

    func received(segment index: Int) -> Int64 {
        lock.withLock { segments[index].receivedBytes }
    }

    var reading: Reading {
        lock.withLock {
            let kept = keptSegments
            return Reading(
                // File order, also after stealing appended segments.
                segments: kept,
                receivedBytes: unsegmentedBytes + kept.reduce(0) { $0 + $1.receivedBytes },
                activeConnections: kept.filter(\.isActive).count
            )
        }
    }

    private var keptSegments: [SegmentProgress] {
        segments.indices.filter { !rolledBack[$0] }.map { segments[$0] }.sorted { $0.start < $1.start }
    }

    var shownLayout: [ByteRange] {
        lock.withLock {
            guard let end = keptSegments.map(\.end).max() else { return [] }
            let starts = shownStarts.sorted()
            return starts.indices.map { index in
                ByteRange(start: starts[index], end: index + 1 < starts.count ? starts[index + 1] - 1 : end)
            }
        }
    }

    func splitShown() -> Int? {
        lock.withLock {
            guard let index = splitLocked() else { return nil }
            shownStarts.insert(segments[index].start)
            return index
        }
    }

    func waitingSegments() -> [Int] {
        lock.withLock {
            segments.indices
                .filter { !rolledBack[$0] && !segments[$0].isActive && segments[$0].missesBytes }
                .sorted { segments[$0].start < segments[$1].start }
        }
    }

    func isUnfinished(segment index: Int) -> Bool {
        lock.withLock { !rolledBack[index] && segments[index].missesBytes }
    }

    func rollBack(segment index: Int) -> Bool {
        lock.withLock {
            guard !rolledBack[index], segments[index].receivedBytes == 0 else { return false }
            let start = segments[index].start
            guard let previous = segments.indices.first(where: { !rolledBack[$0] && $0 != index && segments[$0].end == start - 1 })
            else { return false }
            segments[previous].end = segments[index].end
            segments[index].isActive = false
            rolledBack[index] = true
            shownStarts.remove(start)
            return true
        }
    }

    /// Whether the segments cover byte 0 to `total` exactly, each one after the other with no gap
    /// and no overlap, and each holds exactly its own length.
    func coversFile(of total: Int64) -> Bool {
        lock.withLock {
            var next: Int64 = 0
            for segment in keptSegments {
                guard segment.start == next, segment.receivedBytes == segment.end - segment.start + 1 else { return false }
                next = segment.end + 1
            }
            return next == total
        }
    }

    /// How many segments there are, including ones stealing added.
    var segmentCount: Int { lock.withLock { segments.count } }

    /// Segment `index`'s current bounds. Its end moves earlier when another connection steals.
    func range(segment index: Int) -> ByteRange {
        lock.withLock { ByteRange(start: segments[index].start, end: segments[index].end) }
    }

    func missing(segment index: Int) -> ByteRange {
        lock.withLock {
            let segment = segments[index]
            return ByteRange(start: segment.start + segment.receivedBytes, end: segment.end)
        }
    }

    /// Takes on up to `length` bytes of segment `index` from `offset`, and returns how many fall
    /// inside the segment's current end. The connection writes only those, then adds them.
    func claim(_ length: Int64, at offset: Int64, segment index: Int) -> Int64 {
        lock.withLock {
            let allowed = max(0, min(length, segments[index].end - offset + 1))
            claimed[index] = offset + allowed - segments[index].start
            return allowed
        }
    }

    /// Lets a connection that finished its segment take over work: the second half of the largest
    /// part no connection has taken on yet (`SegmentPlanner.steal`). Returns the new segment's
    /// index, or `nil` when nothing can be stolen.
    func steal() -> Int? {
        lock.withLock { splitLocked() }
    }

    private func splitLocked() -> Int? {
        let remaining: [ByteRange?] = segments.indices.map { index in
            guard !rolledBack[index] else { return nil }
            let start = segments[index].start + max(claimed[index], segments[index].receivedBytes)
            return start <= segments[index].end ? ByteRange(start: start, end: segments[index].end) : nil
        }
        guard let steal = SegmentPlanner.steal(from: remaining) else { return nil }
        segments[steal.victim].end = steal.kept.end
        segments.append(SegmentProgress(start: steal.taken.start, end: steal.taken.end))
        claimed.append(0)
        rolledBack.append(false)
        return segments.count - 1
    }

}

private extension SegmentProgress {
    var missesBytes: Bool { receivedBytes < end - start + 1 }
}

/// Speed over the last 5 seconds, from samples of the received byte count.
struct SpeedMeter {
    static let window: Duration = .seconds(5)

    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []

    /// Records the count at `time` and returns bytes per second over the window.
    mutating func record(_ bytes: Int64, at time: ContinuousClock.Instant) -> Int64 {
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > Self.window }
        guard let oldest = samples.first, time > oldest.time else { return 0 }
        let seconds = (time - oldest.time) / .seconds(1)
        return Int64(Double(bytes - oldest.bytes) / seconds)
    }
}
