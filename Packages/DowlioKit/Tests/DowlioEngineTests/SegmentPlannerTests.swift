@testable import DowlioEngine
import Testing

struct SegmentRampTests {
    static func segments(size: Int64, connections: Int) -> [ByteRange] {
        var remaining: [ByteRange?] = SegmentPlanner.firstSegment(size: size)
        for _ in 1..<max(connections, 1) {
            guard let split = SegmentPlanner.steal(from: remaining) else { break }
            remaining[split.victim] = split.kept
            remaining.append(split.taken)
        }
        return remaining.compactMap { $0 }.sorted { $0.start < $1.start }
    }

    @Test(arguments: [
        (Int64(131_072), 1),
        (245_759, 1),
        (245_760, 2),
        (393_216, 2),
        (524_288, 4),
        (1_048_576, 8),
        (104_857_600, 8),
    ])
    func eightConnectionsSplitAFileIntoHalvesOfAtLeast120KiB(size: Int64, count: Int) {
        #expect(Self.segments(size: size, connections: 8).count == count)
    }

    @Test func splitsGoInHalvesThenQuartersThenEighths() {
        let size: Int64 = 104_857_600
        let starts = Self.segments(size: size, connections: 8).map(\.start)
        #expect(starts == (0..<8).map { size * Int64($0) / 8 })
    }

    @Test(arguments: [1, 2, 4, 8, 16])
    func theSegmentsCoverTheFileExactly(connections: Int) {
        for size: Int64 in [1, 122_880, 245_760, 5_000_000, 4_700_000_123] {
            let segments = Self.segments(size: size, connections: connections)
            #expect(segments.first?.start == 0)
            #expect(segments.last?.end == size - 1)
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end + 1 == $1.start })
            #expect(segments.count <= connections)
        }
    }

    static let rampUpCounts: [(missing: Int64, wanted: Int, opened: Int)] = [
        (131_072 - 16_384, 7, 0),
        (262_144 - 16_384, 7, 1),
        (524_288 - 32_768, 6, 2),
        (1_048_576 - 49_152, 6, 4),
        (2_097_152 - 49_152, 6, 6),
        (104_857_600, 6, 6),
        (104_857_600, 0, 0),
    ]

    @Test(arguments: rampUpCounts)
    func theRampUpOpensOneConnectionPer240KiBStillMissing(missing: Int64, wanted: Int, opened: Int) {
        #expect(SegmentPlanner.connectionsWorthOpening(missing: missing, wanted: wanted) == opened)
    }

    @Test func anEmptyFileHasNoSegment() {
        #expect(SegmentPlanner.firstSegment(size: 0).isEmpty)
    }
}

/// Stealing. Expected splits are worked out by hand: a free connection takes the second
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
            name: "exactly 240 KiB splits into two 120 KiB halves",
            remaining: [nil, 1_000_000...1_245_759],
            expected: Expected(victim: 1, kept: 1_000_000...1_122_879, taken: 1_122_880...1_245_759)
        ),
        Case(name: "just under 240 KiB can't be split", remaining: [0...245_758, nil], expected: nil),
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
}
