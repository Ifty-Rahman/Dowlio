import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SegmentedDownloadTests {
    @Test func aLargeFileDownloadsOverEightConnectionsByDefault() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 64 * 1024 * 1024, seed: 21)
        server.serve(.init(data: data), at: "/big.iso")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/big.iso"), to: folder)
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "big.iso")) == TestFiles.sha256(data))
        let segmentRanges = server.requests.dropFirst().compactMap { $0.headers["range"] }.sorted()
        #expect(segmentRanges == [
            "bytes=0-8388607", "bytes=16777216-25165823", "bytes=25165824-33554431",
            "bytes=33554432-41943039", "bytes=41943040-50331647", "bytes=50331648-58720255",
            "bytes=58720256-67108863", "bytes=8388608-16777215",
        ])
    }

    @Test func theConnectionSettingDecidesHowManyConnectionsOpen() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 12 * 1024 * 1024, seed: 22)
        server.serve(.init(data: data), at: "/three.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 3

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/three.bin"), to: folder, options: options)
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "three.bin")) == TestFiles.sha256(data))
        #expect(server.requests.dropFirst().compactMap { $0.headers["range"] }.sorted() == [
            "bytes=0-4194303", "bytes=4194304-8388607", "bytes=8388608-12582911",
        ])
    }

    @Test func extraConnectionsWaitUntilTheFirstOneReceivesData() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 24)
        server.serve(.init(data: data, holdAfterBytes: 0), at: "/ramp.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/ramp.bin"), to: folder)
        try await waitUntil { server.requests.count >= 2 }
        // The first connection has no data yet, so no other connection may open.
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.requests.count == 2)

        server.releaseHeldResponses()
        let finished = try await engine.finished(id)
        #expect(finished.state == .completed)
        #expect(server.requests.count == 9)
    }

    @Test func allAtOnceOpensEveryConnectionWithoutWaiting() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 25)
        server.serve(.init(data: data, holdAfterBytes: 0), at: "/burst.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.openExtraConnections = .allAtOnce

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/burst.bin"), to: folder, options: options)
        // Every body is held at its first byte, so all 8 requests must arrive without any data.
        try await waitUntil { server.requests.count == 9 }

        server.releaseHeldResponses()
        let finished = try await engine.finished(id)
        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "burst.bin")) == TestFiles.sha256(data))
    }

    @Test func snapshotsShowEachSegmentsProgress() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 26)
        let held = 512 * 1024
        server.serve(.init(data: data, holdAfterBytes: held), at: "/bar.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/bar.bin"), to: folder)
        let midway = try await engine.firstSnapshot(of: id) {
            $0.receivedBytes == Int64(8 * held) && $0.bytesPerSecond > 0
        }

        #expect(midway.segments.map { $0.start...$0.end } == [
            0...1_048_575, 1_048_576...2_097_151, 2_097_152...3_145_727, 3_145_728...4_194_303,
            4_194_304...5_242_879, 5_242_880...6_291_455, 6_291_456...7_340_031, 7_340_032...8_388_607,
        ])
        #expect(midway.segments.allSatisfy { $0.receivedBytes == Int64(held) && $0.isActive })
        #expect(midway.activeConnections == 8)
        #expect(midway.timeRemaining != nil)

        server.releaseHeldResponses()
        let finished = try await engine.finished(id)
        #expect(finished.state == .completed)
        #expect(finished.segments.allSatisfy { $0.receivedBytes == 1_048_576 && !$0.isActive })
        #expect(finished.activeConnections == 0)
    }

    struct ValidatorCase: Sendable, CustomTestStringConvertible {
        let eTag: String?
        let lastModified: String?
        let expectedIfRange: String?
        let testDescription: String
    }

    static let validatorCases: [ValidatorCase] = [
        ValidatorCase(eTag: "\"v1-abc\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
                      expectedIfRange: "\"v1-abc\"", testDescription: "a strong ETag wins"),
        ValidatorCase(eTag: "W/\"weak\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
                      expectedIfRange: "Wed, 21 Oct 2026 07:28:00 GMT", testDescription: "a weak ETag falls back to Last-Modified"),
        ValidatorCase(eTag: nil, lastModified: nil, expectedIfRange: nil, testDescription: "no validator sends no If-Range"),
    ]

    @Test(arguments: validatorCases)
    func everySegmentRequestCarriesTheValidator(_ testCase: ValidatorCase) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 4 * 1024 * 1024, seed: 23)
        server.serve(.init(data: data, eTag: testCase.eTag, lastModified: testCase.lastModified), at: "/tagged.zip")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: "/tagged.zip"), to: folder)
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        let segmentRequests = Array(server.requests.dropFirst())
        #expect(segmentRequests.count == 4)
        #expect(segmentRequests.allSatisfy { $0.headers["if-range"] == testCase.expectedIfRange })
        #expect(server.requests.first?.headers["if-range"] == nil)
    }
}
