import CoreMedia
import DowlioMedia
import Testing

struct TrackPlacementTests {
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    @Test func aTrackThatStartsWithTheVideoIsLeftWhereItIs() {
        let placed = TrackPlacement.place(range(0.02, 371), against: range(0, 371))

        #expect(placed.at.seconds == 0.02)
        #expect(placed.keeping.duration.seconds == 371)
    }

    @Test func aTrackThatStartsMinutesAfterTheVideoIsMovedToTheVideosStart() {
        let placed = TrackPlacement.place(range(378, 371), against: range(0, 371))

        #expect(placed.at.seconds == 0)
        #expect(placed.keeping.duration.seconds == 371)
    }

    @Test func aTrackThatRunsFarPastTheVideoIsCutAtTheVideosEnd() {
        let placed = TrackPlacement.place(range(0, 749), against: range(0, 371))

        #expect(placed.at.seconds == 0)
        #expect(placed.keeping.duration.seconds == 371)
    }

    @Test func aTrackThatRunsALittlePastTheVideoIsKeptWhole() {
        let placed = TrackPlacement.place(range(0, 373), against: range(0, 371))

        #expect(placed.keeping.duration.seconds == 373)
    }

    @Test func withNoVideoTheTrackIsKeptWhole() {
        let placed = TrackPlacement.place(range(4, 100), against: nil)

        #expect(placed.at.seconds == 4)
        #expect(placed.keeping.duration.seconds == 100)
    }
}
