import DowlioLibrary
import Foundation
import Testing

/// The detail window's speed graph: what was measured while the window was open, for the last 60
/// seconds.
struct SpeedHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aNewHistoryIsEmpty() {
        #expect(SpeedHistory().samples.isEmpty)
    }

    @Test func samplesKeepTheirOrderAndAgeFromTheNewest() {
        var history = SpeedHistory()
        history.record(1_000, at: start)
        history.record(3_000, at: start.addingTimeInterval(1))
        history.record(2_000, at: start.addingTimeInterval(2))

        #expect(history.samples.map(\.bytesPerSecond) == [1_000, 3_000, 2_000])
        #expect(history.samples.map(\.secondsAgo) == [2, 1, 0])
        #expect(history.peak == 3_000)
    }

    @Test func samplesOlderThanSixtySecondsDropOff() {
        var history = SpeedHistory()
        history.record(5, at: start)
        history.record(6, at: start.addingTimeInterval(30))
        history.record(7, at: start.addingTimeInterval(61))

        #expect(history.samples.map(\.bytesPerSecond) == [6, 7])
    }
}
