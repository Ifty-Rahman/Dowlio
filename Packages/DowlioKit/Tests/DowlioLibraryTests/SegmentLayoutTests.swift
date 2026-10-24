import DowlioCore
import DowlioLibrary
import Testing

/// The download list's bar keeps the segments the download started with. Work stealing splits
/// segments under the hood, and each original piece shows the bytes of every part inside it.
struct SegmentLayoutTests {
    private let planned = [SegmentBounds(start: 0, end: 99), SegmentBounds(start: 100, end: 199)]

    @Test func withoutStealingTheBarShowsTheSegmentsAsTheyAre() {
        let current = [segment(0, 99, 40, active: true), segment(100, 199, 10, active: true)]
        #expect(SegmentLayout.shown(planned: planned, current: current) == current)
    }

    @Test func aStolenHalfStillFillsItsOriginalPiece() {
        let current = [
            segment(0, 99, 100),
            segment(100, 149, 50),
            segment(150, 199, 20, active: true),
        ]
        #expect(SegmentLayout.shown(planned: planned, current: current) == [
            segment(0, 99, 100),
            segment(100, 199, 70, active: true),
        ])
    }

    @Test func aPieceSplitSeveralTimesStaysOnePiece() {
        let current = [
            segment(0, 99, 100),
            segment(100, 124, 25),
            segment(150, 199, 50),
            segment(125, 149, 25),
        ]
        #expect(SegmentLayout.shown(planned: planned, current: current) == [segment(0, 99, 100), segment(100, 199, 100)])
    }

    @Test func aSizeNotYetKnownShowsNoSegments() {
        #expect(SegmentLayout.shown(planned: planned, current: []).isEmpty)
    }

    @Test(arguments: [
        ([segment(0, 99, 0), segment(100, 199, 0)], true),
        ([segment(0, 99, 0), segment(100, 149, 0), segment(150, 199, 0)], true),
        ([segment(0, 199, 0)], false),
        ([segment(0, 49, 0), segment(50, 99, 0)], false),
        ([segment(0, 99, 0), segment(100, 299, 0)], false),
    ])
    func theOriginalLayoutHoldsOnlyWhileEveryOriginalPieceStillStartsASegment(current: [SegmentProgress], holds: Bool) {
        #expect(SegmentLayout.stillMatches(planned: planned, current: current) == holds)
    }

    @Test func boundsComeFromTheSegments() {
        #expect(SegmentLayout.bounds(of: [segment(0, 99, 5), segment(100, 199, 0)]) == planned)
    }
}

private func segment(_ start: Int64, _ end: Int64, _ received: Int64, active: Bool = false) -> SegmentProgress {
    SegmentProgress(start: start, end: end, receivedBytes: received, isActive: active)
}
