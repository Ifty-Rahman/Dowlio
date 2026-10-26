import AVFoundation
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

struct AVRemuxerTests {
    private func media(_ name: String) throws -> Data {
        try TestMedia.data(name)
    }

    private func check(_ output: URL) async throws {
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        #expect(Set(tracks.map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
        #expect(try await tracks.first { $0.mediaType == .video }!.load(.isPlayable))
    }

    @Test func joinedTransportStreamSegmentsBecomeAnMP4() async throws {
        let folder = try TestFiles.makeFolder()
        let joined = folder.appending(path: "joined.ts")
        try (media("ts0.ts") + media("ts1.ts") + media("ts2.ts")).write(to: joined)
        let output = folder.appending(path: "clip.mp4")

        try await AVRemuxer.remux([joined], to: output)

        try await check(output)
    }

    @Test func fragmentedMP4SegmentsAfterTheirInitSegmentBecomeAnMP4() async throws {
        let folder = try TestFiles.makeFolder()
        let joined = folder.appending(path: "joined.mp4")
        try (media("init.mp4") + media("frag0.m4s") + media("frag1.m4s") + media("frag2.m4s")).write(to: joined)
        let output = folder.appending(path: "clip.mp4")

        try await AVRemuxer.remux([joined], to: output)

        try await check(output)
    }

    @Test func somethingThatIsntMediaFailsWithAClearError() async throws {
        let folder = try TestFiles.makeFolder()
        let joined = folder.appending(path: "joined.ts")
        try Data("not a video".utf8).write(to: joined)

        await #expect(throws: AVRemuxer.Error.unreadable) { try await AVRemuxer.remux([joined], to: folder.appending(path: "out.mp4")) }
    }
}
