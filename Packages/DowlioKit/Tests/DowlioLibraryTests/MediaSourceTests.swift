import DowlioCore
import DowlioLibrary
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MediaSourceTests {
    private let media = try! MediaSource(tracks: [
        MediaTrack(kind: .video, fragments: [MediaFragment(url: URL(string: "https://cdn.example/clip/video.mp4")!)]),
        MediaTrack(kind: .audio, fragments: [MediaFragment(url: URL(string: "https://cdn.example/clip/audio.m4a")!)]),
    ])

    @Test func aMediaDownloadIsKeptAsMediaAcrossARelaunch() async throws {
        let fixture = try await LibraryFixture()
        let id = await fixture.library.add(
            .media(media), destination: .folder(fixture.folder), options: RequestOptions(), startImmediately: false
        )

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }
        await relaunched.library.resume(id)
        let failed = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(restored.state == .paused)
        #expect(restored.sourceURL == URL(string: "https://cdn.example/clip/video.mp4"))
        #expect(failed.host == "cdn.example")
    }

    @Test func retryingAFailedMediaDownloadDoesntHoldADownloadSlot() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder))
        _ = try await fixture.library.row(id) { $0.hasEnded }

        await fixture.library.retry(id)
        let next = await fixture.add(URL(string: "http://127.0.0.1:9/next.bin")!)
        let row = try await fixture.library.row(next) { $0.state != .queued }

        #expect(row.state != .queued)
    }
}
