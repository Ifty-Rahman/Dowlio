import AVFoundation
import Foundation

public enum AVRemuxer {
    public enum Error: Swift.Error, Equatable {
        case unreadable
        case exportFailed(String)
    }

    public static func remux(_ inputs: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for input in inputs {
            let asset = AVURLAsset(url: input)
            guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { throw Error.unreadable }
            for track in tracks where track.mediaType == .video || track.mediaType == .audio {
                let range = try await track.load(.timeRange)
                let added = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                try added?.insertTimeRange(range, of: track, at: range.start)
            }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Error.exportFailed("No passthrough export for this media")
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            throw Error.exportFailed(error.localizedDescription)
        }
    }
}
