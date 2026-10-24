import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

/// The download list shows the segments a download started with, whatever stealing does under the
/// hood. The inspector's segments show the real split.
@Suite(.timeLimit(.minutes(1)))
struct OriginalSegmentsTests {
    static let mebibyte = 1_048_576

    @Test func theListKeepsTheOriginalSegmentsWhileStealingSplitsThem() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 32 * Self.mebibyte, seed: 700)
        server.serve(.init(data: data, eTag: "\"o1\"", throttle: .init(rangeStart: 24 * Self.mebibyte, bytesPerSecond: Self.mebibyte)), at: "/split.iso")
        var options = RequestOptions()
        options.connections = 4

        let recording = Task {
            var shownCounts: Set<Int> = []
            var mostReal = 0
            var last: DownloadRow?
            for await rows in await fixture.library.rows() {
                guard let row = rows.first else { continue }
                if !row.displaySegments.isEmpty { shownCounts.insert(row.displaySegments.count) }
                mostReal = max(mostReal, row.segments.count)
                last = row
                if row.state == .completed { break }
            }
            return (shownCounts, mostReal, last)
        }
        _ = await fixture.add(server.url(for: "/split.iso"), options: options)
        let (shownCounts, mostReal, last) = await recording.value

        #expect(shownCounts == [4])
        #expect(mostReal > 4)
        let finished = try #require(last)
        #expect(finished.displaySegments.allSatisfy { $0.receivedBytes == $0.end - $0.start + 1 })
        #expect(finished.displaySegments.map(\.start) == [0, 8, 16, 24].map { Int64($0 * Self.mebibyte) })

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(finished.id) { _ in true }
        #expect(restored.state == .completed)
    }

    @Test func aPausedDownloadKeepsItsOriginalSegmentsAfterARelaunch() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 32 * Self.mebibyte, seed: 701)
        server.serve(.init(data: data, eTag: "\"o2\"", throttle: .init(rangeStart: 24 * Self.mebibyte, bytesPerSecond: Self.mebibyte)), at: "/later.iso")
        var options = RequestOptions()
        options.connections = 4

        let id = await fixture.add(server.url(for: "/later.iso"), options: options)
        _ = try await fixture.library.row(id) { $0.segments.count > 4 }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { !$0.segments.isEmpty }
        #expect(restored.segments.count > 4)
        #expect(restored.displaySegments.map(\.start) == [0, 8, 16, 24].map { Int64($0 * Self.mebibyte) })
    }
}
