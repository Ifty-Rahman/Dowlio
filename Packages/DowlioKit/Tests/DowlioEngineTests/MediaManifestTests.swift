import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

struct MediaManifestTests {
    @Test func aPartialFileRecordsItsMediaSourceAndWhichFragmentsAreFinished() throws {
        let package = try TestFiles.makeFolder()
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: [
            MediaFragment(url: URL(string: "https://cdn.example/s0.ts")!),
            MediaFragment(url: URL(string: "https://cdn.example/s1.ts")!),
            MediaFragment(url: URL(string: "https://cdn.example/s2.ts")!),
        ])])
        var manifest = Self.manifest(formatVersion: PartialFileManifest.currentFormatVersion)
        manifest.mediaSource = media
        manifest.finishedFragments = [FragmentPosition(track: 0, fragment: 0), FragmentPosition(track: 0, fragment: 2)]
        try JSONEncoder().encode(manifest).write(to: package.appending(path: "manifest.json"))

        let read = try PartialFile.readManifest(in: package)

        #expect(read.mediaSource == media)
        #expect(read.finishedFragments == [FragmentPosition(track: 0, fragment: 0), FragmentPosition(track: 0, fragment: 2)])
    }

    @Test func aFormatThreePartialFileStillReadsAsAFile() throws {
        let package = try TestFiles.makeFolder()
        let saved = """
            {"formatVersion":3,"downloadID":"\(UUID().uuidString)","originalURL":"https://example.com/a.iso",
            "finalURL":"https://example.com/a.iso","totalBytes":10,"fileName":"a.iso","connections":8,
            "segments":[{"start":0,"end":9,"received":4}],"layout":"ranges","nameConflictPolicy":"keepBoth"}
            """
        try Data(saved.utf8).write(to: package.appending(path: "manifest.json"))

        let read = try PartialFile.readManifest(in: package)

        #expect(read.mediaSource == nil)
        #expect(read.finishedFragments == nil)
        #expect(read.segments.first?.received == 4)
    }

    private static func manifest(formatVersion: Int) -> PartialFileManifest {
        PartialFileManifest(
            formatVersion: formatVersion, downloadID: UUID().uuidString,
            originalURL: URL(string: "https://cdn.example/s0.ts")!, finalURL: URL(string: "https://cdn.example/s0.ts")!,
            validator: nil, totalBytes: nil, fileName: "clip.mp4", connections: 8, referrer: nil, userAgent: nil,
            segments: [], layout: .whole, nameConflictPolicy: .keepBoth
        )
    }
}
