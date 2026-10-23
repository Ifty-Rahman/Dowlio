import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Seam 1: work stealing through the engine's interface. One segment's replies trickle out, and
/// connections that finish early take over half of what it has left.
@Suite(.timeLimit(.minutes(1)))
struct WorkStealingTests {
    static let mebibyte = 1_048_576

    /// A 32 MiB file over 4 connections: segments of 8 MiB. The last one trickles at 1 MiB a second,
    /// so on its own it would take 8 seconds.
    static let size = 32 * mebibyte
    static let slowStart = 24 * mebibyte
    static let slowSpeed = mebibyte

    @Test func aSlowSegmentIsSplitSoTheDownloadFinishesFarSooner() async throws {
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
        let started = ContinuousClock.now
        let id = await engine.add(url: server.url(for: "/big.iso"), to: folder, options: options)
        var snapshots: [DownloadSnapshot] = []
        for await snapshot in await engine.snapshots(of: id) {
            snapshots.append(snapshot)
        }
        let elapsed = ContinuousClock.now - started

        #expect(snapshots.last?.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "big.iso")) == TestFiles.sha256(data))
        // Alone, the slow segment needs 8 seconds. Stealing must at least halve that.
        #expect(elapsed < .seconds(4))
        // The snapshots show the slow segment cut short and new segments taking its end.
        let slowEnds = snapshots.flatMap(\.segments).filter { $0.start == Int64(Self.slowStart) }.map(\.end)
        #expect(slowEnds.contains { $0 < Int64(Self.size - 1) })
        #expect(snapshots.contains { $0.segments.count > 4 })
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
        let finished = try await engine.finished(id)

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
