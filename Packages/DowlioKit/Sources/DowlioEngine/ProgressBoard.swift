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
    private var segments: [SegmentProgress]
    /// Bytes of a download whose size is unknown, so it has no segments.
    private var unsegmentedBytes: Int64 = 0

    init(segments: [ByteRange]) {
        self.segments = segments.map { SegmentProgress(start: $0.start, end: $0.end) }
    }

    /// A board for segments that already hold `received` bytes each, from a restored manifest.
    convenience init(segments: [ByteRange], received: [Int64]) {
        self.init(segments: segments)
        for (index, count) in received.enumerated() { add(count, to: index) }
    }

    /// Adds `bytes` to segment `index`, or to the unsegmented count when the size is unknown.
    func add(_ bytes: Int64, to index: Int?) {
        lock.withLock {
            if let index { segments[index].receivedBytes += bytes } else { unsegmentedBytes += bytes }
        }
    }

    /// Forgets every byte received, for a download that starts over.
    func reset() {
        lock.withLock {
            for index in segments.indices { segments[index].receivedBytes = 0 }
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
            Reading(
                segments: segments,
                receivedBytes: unsegmentedBytes + segments.reduce(0) { $0 + $1.receivedBytes },
                activeConnections: segments.filter(\.isActive).count
            )
        }
    }

    /// Whether every segment holds exactly its own length.
    var coversEverySegment: Bool {
        lock.withLock { segments.allSatisfy { $0.receivedBytes == $0.end - $0.start + 1 } }
    }
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
