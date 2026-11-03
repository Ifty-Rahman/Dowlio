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

    @Test func aLastFrameHeldForMinutesIsCutToOneFrame() {
        let trusted = TrackPlacement.trusted(
            range(0, 5205.3), lastSampleStart: CMTime(seconds: 2602.6, preferredTimescale: 90000),
            lastSampleDuration: CMTime(seconds: 2602.7, preferredTimescale: 90000), typicalSampleDuration: CMTime(seconds: 1.0 / 30, preferredTimescale: 90000)
        )

        #expect(abs(trusted.duration.seconds - 2602.6333) < 0.001)
    }

    @Test func aLongLastFrameOfAStillPictureStaysAsItIs() {
        let trusted = TrackPlacement.trusted(
            range(0, 20), lastSampleStart: CMTime(seconds: 15, preferredTimescale: 600),
            lastSampleDuration: CMTime(seconds: 5, preferredTimescale: 600), typicalSampleDuration: CMTime(seconds: 5, preferredTimescale: 600)
        )

        #expect(trusted.duration.seconds == 20)
    }

    @Test func aNormalLastFrameLeavesTheRangeAlone() {
        let trusted = TrackPlacement.trusted(
            range(0, 371), lastSampleStart: CMTime(seconds: 370.96, preferredTimescale: 600),
            lastSampleDuration: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), typicalSampleDuration: CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        )

        #expect(trusted.duration.seconds == 371)
    }

    @Test func aDeclaredLengthTwiceTheSamplesIsCutToWhereTheSamplesEnd() {
        let trusted = TrackPlacement.trusted(
            range(0, 5205.3), lastSampleStart: CMTime(seconds: 2602.6, preferredTimescale: 90000),
            lastSampleDuration: CMTime(seconds: 1.0 / 30, preferredTimescale: 90000), typicalSampleDuration: CMTime(seconds: 1.0 / 30, preferredTimescale: 90000)
        )

        #expect(abs(trusted.duration.seconds - 2602.6333) < 0.001)
    }
}
