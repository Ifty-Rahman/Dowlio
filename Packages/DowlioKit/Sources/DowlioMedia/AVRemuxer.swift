import AVFoundation
import Foundation

public enum AVRemuxer {
    public enum Error: Swift.Error, Equatable {
        case unreadable
        case exportFailed(String)
    }

    public static func remux(_ inputs: [URL], to output: URL) async throws {
        let audioOnly = output.pathExtension.lowercased() == "m4a"
        let kept: Set<AVMediaType> = audioOnly ? [.audio] : [.video, .audio]
        let composition = AVMutableComposition()
        for input in inputs {
            let asset = AVURLAsset(url: input)
            guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { throw Error.unreadable }
            for track in tracks where kept.contains(track.mediaType) {
                let range = try await timeRange(of: track, in: asset)
                let added = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                try added?.insertTimeRange(range, of: track, at: range.start)
            }
        }
        guard !composition.tracks.isEmpty else { throw Error.unreadable }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Error.exportFailed("No passthrough export for this media")
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: audioOnly ? .m4a : .mp4)
        } catch {
            throw Error.exportFailed(error.localizedDescription)
        }
    }

    private static func timeRange(of track: AVAssetTrack, in asset: AVURLAsset) async throws -> CMTimeRange {
        if let range = try? await track.load(.timeRange) { return range }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else { throw Error.unreadable }
        return CMTimeRange(start: .zero, duration: duration)
    }
}
