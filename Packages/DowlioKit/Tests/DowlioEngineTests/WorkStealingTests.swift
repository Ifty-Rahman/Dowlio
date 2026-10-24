import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Work stealing through the engine's interface. One segment's replies trickle out, and
/// connections that finish early take over half of what it has left.
@Suite(.timeLimit(.minutes(1)))
struct WorkStealingTests {
    static let mebibyte = 1_048_576

    /// A 32 MiB file over 4 connections: segments of 8 MiB. The last one trickles at 1 MiB a second,
    /// so on its own it would take 8 seconds.
    static let size = 32 * mebibyte
    static let slowStart = 24 * mebibyte
    static let slowSpeed = mebibyte

    @Test func otherConnectionsTakeOverTheEndOfASlowSegment() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 31)
        server.serve(
            .init(data: data, eTag: "\"v1\"", throttle: .init(rangeStart: Self.slowStart, bytesPerSecond: Self.slowSpeed)),
            at: "/big.iso"
        )
        let folder = try TestFiles.makeFolder()

        var options = RequestOptions()
        options.connections = 4
        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/big.iso"), to: folder, options: options)
        var snapshots: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) {
            snapshots.append(snapshot)
        }

        let completed = try #require(snapshots.last)
        #expect(completed.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "big.iso")) == TestFiles.sha256(data))
        // The slow segment's own connection was asked for its range once, and the segment ended up
        // shorter than that range: its end moved earlier, and it holds exactly its new length.
        // Requests are matched by start, because stealing can shorten a range before it's asked for.
        let starts = server.requests.compactMap { $0.headers["range"] }.map { range in
            Int64(range.dropFirst("bytes=".count).prefix { $0 != "-" }) ?? -1
        }
        #expect(starts.count { $0 == Int64(Self.slowStart) } == 1)
        let slow = try #require(completed.segments.first { $0.start == Int64(Self.slowStart) })
        #expect(slow.end < Int64(Self.size - 1))
        #expect(slow.receivedBytes == slow.end - slow.start + 1)
        // The rest of its original range went to new segments. Other connections asked for each
        // one from its own start, and each is complete.
        let takenOver = completed.segments.filter { $0.start > slow.end }
        #expect(takenOver.first?.start == slow.end + 1)
        #expect(takenOver.last?.end == Int64(Self.size - 1))
        #expect(takenOver.allSatisfy { segment in
            starts.contains(segment.start) && segment.receivedBytes == segment.end - segment.start + 1
        })
        #expect(completed.segments.count > 4)
        // The plan stays what the download started with, so the interface can keep showing it.
        let planned = (0..<4).map { SegmentBounds(start: Int64($0 * 8 * Self.mebibyte), end: Int64(($0 + 1) * 8 * Self.mebibyte - 1)) }
        #expect(snapshots.filter { !$0.plannedSegments.isEmpty }.allSatisfy { $0.plannedSegments == planned })
        #expect(completed.plannedSegments == planned)
    }

    /// After a split, the manifest describes the new segments, every byte it counts is in the
    /// data file, and Resume asks for exactly each segment's missing part.
    @Test func pauseAfterASplitKeepsTheManifestRightAndResumeFetchesOnlyTheMissingBytes() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 32)
        server.serve(
            .init(data: data, eTag: "\"v1\"", throttle: .init(rangeStart: Self.slowStart, bytesPerSecond: Self.slowSpeed)),
            at: "/split.iso"
        )
        let folder = try TestFiles.makeFolder()
        let package = folder.appending(path: "split.iso.dowlio")

        var options = RequestOptions()
        options.connections = 4
        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/split.iso"), to: folder, options: options)
        _ = try await engine.firstSnapshot(of: id) { $0.segments.count > 4 }
        await engine.pause(id)
        let paused = try await engine.firstSnapshot(of: id) { $0.state == .paused }

        // The manifest lists the same segments as the paused snapshot, in file order, and each
        // segment's counted bytes are the file's own bytes in the data file.
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: package.appending(path: "manifest.json"))) as? [String: Any]
        )
        let saved = try #require(manifest["segments"] as? [[String: Any]]).map { segment in
            (
                start: (segment["start"] as? NSNumber)?.int64Value ?? -1,
                end: (segment["end"] as? NSNumber)?.int64Value ?? -1,
                received: (segment["received"] as? NSNumber)?.int64Value ?? -1
            )
        }
        #expect(saved.map(\.start) == paused.segments.map(\.start))
        #expect(saved.map(\.end) == paused.segments.map(\.end))
        #expect(saved.map(\.received) == paused.segments.map(\.receivedBytes))
        #expect(zip(saved, saved.dropFirst()).allSatisfy { $0.end + 1 == $1.start })
        let onDisk = try Data(contentsOf: package.appending(path: "data"))
        for segment in saved where segment.received > 0 {
            let range = Int(segment.start)..<Int(segment.start + segment.received)
            #expect(onDisk.subdata(in: range) == data.subdata(in: range))
        }

        let requestsBeforeResume = server.requests.count
        await engine.resume(id)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "split.iso")) == TestFiles.sha256(data))
        // Stealing may split segments again after Resume, so the first request for each missing
        // part must start exactly where that part begins.
        let missingStarts = Set(paused.segments.filter { $0.receivedBytes < $0.end - $0.start + 1 }.map { $0.start + $0.receivedBytes })
        let resumeStarts = Set(server.requests[requestsBeforeResume...].compactMap { request -> Int64? in
            guard let range = request.headers["range"], range != "bytes=0-0" else { return nil }
            return Int64(range.dropFirst("bytes=".count).prefix { $0 != "-" })
        })
        #expect(missingStarts.isSubset(of: resumeStarts))
        #expect(!resumeStarts.contains(0))
    }
}
