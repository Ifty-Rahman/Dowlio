import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FFmpegRemuxerTests {
    private func standIn(_ script: String) throws -> URL {
        let file = try TestFiles.makeFolder().appending(path: "ffmpeg")
        try "#!/bin/sh\n\(script)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func request(in folder: URL) throws -> RemuxRequest {
        let track = folder.appending(path: "track.webm")
        try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: track)
        let media = try MediaSource(tracks: [MediaTrack(kind: .video, fragments: [MediaFragment(url: track)])], container: .webm)
        return RemuxRequest(tracks: [track], output: folder.appending(path: "output.webm"), mediaSource: media)
    }

    @Test func aHelperThatRunsPastItsTimeoutIsStoppedAndLeavesNoOutput() async throws {
        let helper = try standIn("for last; do :; done\necho partial > \"$last\"\nexec sleep 30")
        let request = try request(in: helper.deletingLastPathComponent())
        let started = ContinuousClock.now

        await #expect(throws: FFmpegRemuxer.Error.timedOut) {
            try await FFmpegRemuxer(executable: helper, timeout: .milliseconds(300)).remux(request)
        }

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!FileManager.default.fileExists(atPath: request.output.path))
    }

    @Test func aHelperThatFailsReportsWhatItSaid() async throws {
        let helper = try standIn("echo 'Invalid data found when processing input' >&2\nexit 1")
        let request = try request(in: helper.deletingLastPathComponent())

        await #expect(throws: FFmpegRemuxer.Error.failed("Invalid data found when processing input")) {
            try await FFmpegRemuxer(executable: helper).remux(request)
        }
    }

    @Test func webMWithoutAHelperSaysTheHelperIsMissing() async throws {
        let request = try request(in: try TestFiles.makeFolder())

        await #expect(throws: MediaRemuxer.Error.noHelper) { try await MediaRemuxer(ffmpeg: nil).remux(request) }
    }
}
