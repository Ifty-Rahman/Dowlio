@testable import DowlioEngine
import Testing

/// Seam 2: the segment planner as pure logic. Expected segments are worked out by hand from the
/// spec: at most the connection setting (1 to 16), and never a segment under 1 MiB.
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
