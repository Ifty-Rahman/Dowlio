import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

/// The limit on downloads running at once, and Pause All and Resume All.
@Suite(.timeLimit(.minutes(1)))
struct QueueTests {
    @Test func aDownloadBeyondTheLimitWaitsQueuedAndStartsWhenASlotFrees() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(2)
        let server = try await TestServer()
        let files = try Self.serveHeld(["a", "b", "c"], on: server)

        let a = await fixture.add(server.url(for: "/a.bin"))
        let b = await fixture.add(server.url(for: "/b.bin"))
        let c = await fixture.add(server.url(for: "/c.bin"))
        _ = try await fixture.library.row(b) { $0.receivedBytes > 0 }
        let waiting = try await fixture.library.row(c) { _ in true }

        #expect(waiting.state == .queued)
        #expect(waiting.stateWord == "Queued")
        #expect(!server.requests.contains { $0.path == "/c.bin" })

        server.releaseHeldResponses()
        for id in [a, b, c] { _ = try await fixture.library.row(id) { $0.state == .completed } }
        #expect(try TestFiles.sha256(of: fixture.folder.appending(path: "c.bin")) == TestFiles.sha256(files["c"]!))
    }

    @Test func raisingTheLimitStartsAQueuedDownloadAtOnce() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b"], on: server)

        _ = await fixture.add(server.url(for: "/a.bin"))
        let b = await fixture.add(server.url(for: "/b.bin"))
        _ = try await fixture.library.row(b) { $0.state == .queued }
        await fixture.library.setMaximumActive(2)

        let started = try await fixture.library.row(b) { $0.receivedBytes > 0 }
        #expect(started.state == .downloading)
        server.releaseHeldResponses()
    }

    @Test func pauseAllPausesWhatRunsOrWaitsAndLeavesFailedAlone() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b"], on: server)

        let failed = await fixture.add(server.url(for: "/missing.bin"))
        _ = try await fixture.library.row(failed) { $0.stateWord == "Failed" }
        let running = await fixture.add(server.url(for: "/a.bin"))
        let waiting = await fixture.add(server.url(for: "/b.bin"))
        _ = try await fixture.library.row(running) { $0.receivedBytes > 0 }
        _ = try await fixture.library.row(waiting) { $0.state == .queued }

        await fixture.library.pauseAll()
        let rows = try await fixture.library.firstRows { rows in
            rows.first { $0.id == running }?.state == .paused && rows.first { $0.id == waiting }?.state == .paused
        }

        #expect(rows.first { $0.id == failed }?.state == .failed(.notFound))
        server.releaseHeldResponses()
    }

    @Test func resumeAllResumesPausedDownloadsOldestFirstUpToTheLimit() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b", "c"], on: server)

        let a = await fixture.add(server.url(for: "/a.bin"), startImmediately: false)
        let b = await fixture.add(server.url(for: "/b.bin"), startImmediately: false)
        let c = await fixture.add(server.url(for: "/c.bin"), startImmediately: false)
        _ = try await fixture.library.row(c) { _ in true }
        await fixture.library.resumeAll()

        let rows = try await fixture.library.firstRows { rows in rows.first { $0.id == a }?.receivedBytes ?? 0 > 0 }
        #expect(rows.first { $0.id == a }?.state == .downloading)
        #expect(rows.first { $0.id == b }?.state == .queued)
        #expect(rows.first { $0.id == c }?.state == .queued)
        server.releaseHeldResponses()
    }

    @Test func aPausedQueuedDownloadStaysOutOfTheQueue() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b"], on: server)

        let a = await fixture.add(server.url(for: "/a.bin"))
        let b = await fixture.add(server.url(for: "/b.bin"))
        _ = try await fixture.library.row(b) { $0.state == .queued }
        await fixture.library.pause(b)
        _ = try await fixture.library.row(b) { $0.state == .paused }

        server.releaseHeldResponses()
        _ = try await fixture.library.row(a) { $0.state == .completed }
        let afterwards = try await fixture.library.row(b) { _ in true }
        #expect(afterwards.state == .paused)
        #expect(!server.requests.contains { $0.path == "/b.bin" })
    }

    @Test func aResumedDownloadWaitsItsTurnWhenTheLimitIsReached() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b"], on: server)

        let b = await fixture.add(server.url(for: "/b.bin"), startImmediately: false)
        let a = await fixture.add(server.url(for: "/a.bin"))
        _ = try await fixture.library.row(a) { $0.receivedBytes > 0 }
        await fixture.library.resume(b)

        #expect(try await fixture.library.row(b) { _ in true }.state == .queued)
        server.releaseHeldResponses()
        _ = try await fixture.library.row(b) { $0.state == .completed }
    }

    @Test func quickPausesAndResumesNeverRunMoreThanTheLimit() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b", "c"], on: server)
        let recording = Task {
            var most = 0
            for await rows in await fixture.library.rows() {
                most = max(most, rows.count { LibraryFilter.downloading.includes($0) })
                if rows.count == 3, rows.allSatisfy({ $0.state == .completed }) { break }
            }
            return most
        }

        let a = await fixture.add(server.url(for: "/a.bin"))
        _ = await fixture.add(server.url(for: "/b.bin"))
        _ = await fixture.add(server.url(for: "/c.bin"))
        _ = try await fixture.library.row(a) { $0.receivedBytes > 0 }
        for _ in 0..<5 {
            await fixture.library.pause(a)
            await fixture.library.resume(a)
        }
        server.releaseHeldResponses()

        #expect(await recording.value == 1)
    }

    @Test func pauseAllNeverStartsAQueuedDownload() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(2)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b", "c", "d"], on: server)

        let a = await fixture.add(server.url(for: "/a.bin"))
        let b = await fixture.add(server.url(for: "/b.bin"))
        let c = await fixture.add(server.url(for: "/c.bin"))
        let d = await fixture.add(server.url(for: "/d.bin"))
        _ = try await fixture.library.row(a) { $0.receivedBytes > 0 }
        _ = try await fixture.library.row(b) { $0.receivedBytes > 0 }
        await fixture.library.pauseAll()
        _ = try await fixture.library.firstRows { rows in [a, b, c, d].allSatisfy { id in rows.first { $0.id == id }?.state == .paused } }

        #expect(!server.requests.contains { $0.path == "/c.bin" || $0.path == "/d.bin" })
        server.releaseHeldResponses()
    }

    @Test func aQueuedDownloadBroughtBackByARelaunchStartsOnResume() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        _ = try Self.serveHeld(["a", "b"], on: server)

        let a = await fixture.add(server.url(for: "/a.bin"))
        let b = await fixture.add(server.url(for: "/b.bin"))
        _ = try await fixture.library.row(a) { $0.receivedBytes > 0 }
        _ = try await fixture.library.row(b) { $0.state == .queued }

        let relaunched = try await fixture.relaunched()
        #expect(try await relaunched.library.row(b) { _ in true }.state == .queued)
        await relaunched.library.resume(b)
        server.releaseHeldResponses()
        _ = try await relaunched.library.row(b) { $0.state == .completed }
    }

    @Test func aDownloadAddedToStartIsNeverShownPaused() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        _ = try Self.serveHeld(["a"], on: server)
        let recording = Task {
            var states: [DownloadRow.State] = []
            for await rows in await fixture.library.rows() {
                if let row = rows.first { states.append(row.state) }
                if rows.first?.state == .completed { break }
            }
            return states
        }

        _ = await fixture.add(server.url(for: "/a.bin"))
        server.releaseHeldResponses()

        #expect(await !recording.value.contains(.paused))
    }

    /// One held file per name, at `/<name>.bin`. Each reply stops after 64 KiB until released.
    private static func serveHeld(_ names: [String], on server: TestServer) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (index, name) in names.enumerated() {
            let data = TestServer.makeData(size: 512 * 1024, seed: UInt64(400 + index))
            server.serve(.init(data: data, holdAfterBytes: 64 * 1024, eTag: "\"\(name)\""), at: "/\(name).bin")
            files[name] = data
        }
        return files
    }
}
