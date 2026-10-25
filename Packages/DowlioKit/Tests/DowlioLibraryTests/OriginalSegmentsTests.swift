import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct OriginalSegmentsTests {
    static let mebibyte = 1_048_576
    static let held = 256 * 1024
    static let slowHalf = TestServer.RangeThrottle(rangeStart: 16 * mebibyte, bytesPerSecond: mebibyte, andLater: true)

    @Test func theListKeepsTheOriginalSegmentsWhileStealingSplitsThem() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 32 * Self.mebibyte, seed: 700)
        server.serve(.init(data: data, holdAfterBytes: Self.held, eTag: "\"o1\"", throttle: Self.slowHalf), at: "/split.iso")
        var options = RequestOptions()
        options.connections = 4

        let recording = Task {
            var shownCounts: [Int] = []
            var mostReal = 0
            var last: DownloadRow?
            for await rows in await fixture.library.rows() {
                guard let row = rows.first else { continue }
                if !row.displaySegments.isEmpty, shownCounts.last != row.displaySegments.count {
                    shownCounts.append(row.displaySegments.count)
                }
                mostReal = max(mostReal, row.segments.count)
                last = row
                if row.state == .completed { break }
            }
            return (shownCounts, mostReal, last)
        }
        _ = await fixture.add(server.url(for: "/split.iso"), options: options)
        try await waitUntil { server.requests.count >= 4 }
        server.releaseHeldResponses()
        let (shownCounts, mostReal, last) = await recording.value

        #expect(shownCounts.last == 4)
        #expect(shownCounts == shownCounts.sorted())
        #expect(mostReal > 4)
        let finished = try #require(last)
        #expect(finished.displaySegments.count == 4)
        #expect(finished.displaySegments.first?.start == 0)
        #expect(finished.displaySegments.allSatisfy { $0.receivedBytes == $0.end - $0.start + 1 })

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(finished.id) { _ in true }
        #expect(restored.state == .completed)
    }

    @Test func aPausedDownloadKeepsItsOriginalSegmentsAfterARelaunch() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 32 * Self.mebibyte, seed: 701)
        server.serve(.init(data: data, holdAfterBytes: Self.held, eTag: "\"o2\"", throttle: Self.slowHalf), at: "/later.iso")
        var options = RequestOptions()
        options.connections = 4

        let id = await fixture.add(server.url(for: "/later.iso"), options: options)
        try await waitUntil { server.requests.count >= 4 }
        server.releaseHeldResponses()
        _ = try await fixture.library.row(id) { $0.segments.count > 4 }
        await fixture.library.pause(id)
        let paused = try await fixture.library.row(id) { $0.state == .paused }

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { !$0.segments.isEmpty }
        #expect(restored.segments.count > 4)
        #expect(restored.displaySegments.count == 4)
        #expect(restored.displaySegments.map(\.start) == paused.displaySegments.map(\.start))
    }
}
