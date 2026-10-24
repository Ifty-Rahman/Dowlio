import Foundation

/// Speeds measured over the last 60 seconds, oldest first.
public struct SpeedHistory: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var bytesPerSecond: Int64
        /// Seconds before the newest sample, so the graph's right edge is now.
        public var secondsAgo: TimeInterval
    }

    public static let span: TimeInterval = 60

    private var recorded: [(date: Date, bytesPerSecond: Int64)] = []

    public init() {}

    public mutating func record(_ bytesPerSecond: Int64, at date: Date) {
        recorded.append((date, bytesPerSecond))
        recorded.removeAll { date.timeIntervalSince($0.date) > Self.span }
    }

    public var samples: [Sample] {
        guard let newest = recorded.last?.date else { return [] }
        return recorded.map { Sample(bytesPerSecond: $0.bytesPerSecond, secondsAgo: newest.timeIntervalSince($0.date)) }
    }

    public var peak: Int64 { recorded.map(\.bytesPerSecond).max() ?? 0 }

    public static func == (lhs: SpeedHistory, rhs: SpeedHistory) -> Bool {
        lhs.recorded.elementsEqual(rhs.recorded) { $0.date == $1.date && $0.bytesPerSecond == $1.bytesPerSecond }
    }
}
