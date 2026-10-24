@testable import DowlioEngine
import Testing

/// The segment planner as pure logic. Expected segments are worked out by hand: at most the
/// connection setting (1 to 16), and never a segment under 1 MiB.
struct SegmentPlannerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let size: Int64
        let connections: Int
        let expected: [ClosedRange<Int64>]

        var testDescription: String { "\(size) bytes, \(connections) connections" }
    }

    static let mebibyte: Int64 = 1_048_576

    static let cases: [Case] = [
        // 8 MiB over 8 connections: eight 1 MiB segments.
        Case(size: 8_388_608, connections: 8, expected: [
            0...1_048_575, 1_048_576...2_097_151, 2_097_152...3_145_727, 3_145_728...4_194_303,
            4_194_304...5_242_879, 5_242_880...6_291_455, 6_291_456...7_340_031, 7_340_032...8_388_607,
        ]),
        // 3.5 MiB allows only 3 segments of at least 1 MiB, even with 8 connections.
        Case(size: 3_670_016, connections: 8, expected: [
            0...1_223_337, 1_223_338...2_446_676, 2_446_677...3_670_015,
        ]),
        // Under 2 MiB: one segment.
        Case(size: 1_572_864, connections: 8, expected: [0...1_572_863]),
        Case(size: 100, connections: 8, expected: [0...99]),
        // One connection asked for: one segment.
        Case(size: 8_388_608, connections: 1, expected: [0...8_388_607]),
        // Zero or negative connections count as one.
        Case(size: 8_388_608, connections: 0, expected: [0...8_388_607]),
    ]

    @Test(arguments: cases)
    func planSplitsTheFileIntoTheExpectedSegments(_ testCase: Case) {
        let segments = SegmentPlanner.plan(size: testCase.size, connections: testCase.connections)
        #expect(segments.map { $0.start...$0.end } == testCase.expected)
    }

    @Test(arguments: [1, 2, 4, 8, 16, 20, 64])
    func planCoversEveryFileExactlyWithinTheLimits(connections: Int) {
        let sizes: [Int64] = [1, 1_048_575, 1_048_576, 2_097_151, 2_097_152, 5_000_000, 67_108_864, 4_700_000_123]
        for size in sizes {
            let segments = SegmentPlanner.plan(size: size, connections: connections)
            #expect(segments.first?.start == 0)
            #expect(segments.last?.end == size - 1)
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end + 1 == $1.start })
            #expect(segments.count <= min(connections, 16))
            if segments.count > 1 {
                #expect(segments.allSatisfy { $0.end - $0.start + 1 >= Self.mebibyte })
            }
        }
    }

    @Test func moreThanSixteenConnectionsAreCappedAtSixteen() {
        #expect(SegmentPlanner.plan(size: 67_108_864, connections: 20).count == 16)
    }
}

/// Stealing. Expected splits are worked out by hand: a free connection takes the second
/// half of the largest remaining range, and only when both halves stay at 1 MiB or more.
struct SegmentStealTests {
    static let mebibyte: Int64 = 1_048_576

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// Each segment's part that isn't downloaded yet, or `nil` when it's finished.
        let remaining: [ClosedRange<Int64>?]
        /// The victim, its kept part and the taken part, or `nil` when nothing can be stolen.
        let expected: Expected?

        var testDescription: String { name }
    }

    struct Expected: Sendable {
        let victim: Int
        let kept: ClosedRange<Int64>
        let taken: ClosedRange<Int64>
    }

    static let cases: [Case] = [
        Case(
            name: "the largest remaining range is split at its midpoint",
            remaining: [nil, 4_194_304...8_388_607, 9_437_184...10_485_759],
            expected: Expected(victim: 1, kept: 4_194_304...6_291_455, taken: 6_291_456...8_388_607)
        ),
        Case(
            name: "an odd length keeps the extra byte",
            remaining: [0...2_097_152],
            expected: Expected(victim: 0, kept: 0...1_048_576, taken: 1_048_577...2_097_152)
        ),
        Case(
            name: "exactly 2 MiB splits into two 1 MiB halves",
            remaining: [nil, 3_145_728...5_242_879],
            expected: Expected(victim: 1, kept: 3_145_728...4_194_303, taken: 4_194_304...5_242_879)
        ),
        Case(name: "just under 2 MiB can't be split", remaining: [0...2_097_150, nil], expected: nil),
        Case(name: "every segment finished", remaining: [nil, nil, nil], expected: nil),
        Case(
            name: "31 segments can still split one more",
            remaining: Array(repeating: nil, count: 30) + [0...4_194_303],
            expected: Expected(victim: 30, kept: 0...2_097_151, taken: 2_097_152...4_194_303)
        ),
        Case(
            name: "32 segments split no further",
            remaining: Array(repeating: nil, count: 31) + [0...4_194_303],
            expected: nil
        ),
        Case(
            name: "a tie goes to the first segment",
            remaining: [0...3_145_727, 4_194_304...7_340_031],
            expected: Expected(victim: 0, kept: 0...1_572_863, taken: 1_572_864...3_145_727)
        ),
    ]

    @Test(arguments: cases)
    func aFreeConnectionTakesTheSecondHalfOfTheLargestRemainingRange(_ testCase: Case) {
        let remaining = testCase.remaining.map { $0.map { ByteRange(start: $0.lowerBound, end: $0.upperBound) } }
        let steal = SegmentPlanner.steal(from: remaining)
        if let expected = testCase.expected {
            #expect(steal?.victim == expected.victim)
            #expect(steal?.kept == ByteRange(start: expected.kept.lowerBound, end: expected.kept.upperBound))
            #expect(steal?.taken == ByteRange(start: expected.taken.lowerBound, end: expected.taken.upperBound))
        } else {
            #expect(steal == nil)
        }
    }

    /// Three connections finish at once against one 8 MiB range. Each steal sees the previous one's
    /// result, so the second splits the kept half (a tie, which goes to the first segment) and the
    /// third splits the first taken half.
    @Test func severalConnectionsFinishingAtOnceSplitOneAfterAnother() {
        var remaining: [ByteRange?] = [ByteRange(start: 0, end: 8 * Self.mebibyte - 1)]
        var taken: [ByteRange] = []
        for _ in 0..<3 {
            guard let steal = SegmentPlanner.steal(from: remaining) else { break }
            remaining[steal.victim] = steal.kept
            remaining.append(steal.taken)
            taken.append(steal.taken)
        }

        #expect(taken == [
            ByteRange(start: 4 * Self.mebibyte, end: 8 * Self.mebibyte - 1),
            ByteRange(start: 2 * Self.mebibyte, end: 4 * Self.mebibyte - 1),
            ByteRange(start: 6 * Self.mebibyte, end: 8 * Self.mebibyte - 1),
        ])
        #expect(remaining.compactMap { $0 }.map(\.length).reduce(0, +) == 8 * Self.mebibyte)
    }
}

/// Lowering a host's connection limit after a refusal. Each refusal lowers it by one, never
/// below 1.
struct HostLimitRuleTests {
    @Test(arguments: [(8, 7), (16, 15), (2, 1), (1, 1)])
    func aRefusalLowersTheLimitByOneNeverBelowOne(limit: Int, lowered: Int) {
        #expect(SegmentPlanner.lowered(limit) == lowered)
    }

    @Test(arguments: [
        // A learned limit below the setting wins.
        (8, 3 as Int?, 3),
        // A learned limit above the setting doesn't raise it.
        (4, 10 as Int?, 4),
        // No learned limit: the setting alone.
        (8, nil as Int?, 8),
    ])
    func theSegmentCountRespectsTheHostsLearnedLimit(connections: Int, hostLimit: Int?, segments: Int) {
        let plan = SegmentPlanner.plan(size: 64 * 1_048_576, connections: connections, hostLimit: hostLimit)
        #expect(plan.count == segments)
    }
}
