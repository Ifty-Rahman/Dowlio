import DowlioMedia
import Foundation

extension MediaText {
    public static func summary(of candidate: Candidate) -> String {
        let versions = candidate.versions.filter { !$0.isExtractedAudio }
        let best = versions.max { ($0.height ?? 0, $0.totalBytes ?? 0) < ($1.height ?? 0, $1.totalBytes ?? 0) }
        var parts: [String] = []
        if let best {
            parts.append(title(of: best))
            if let size = size(of: best) { parts.append(size) }
        }
        if let duration = candidate.duration { parts.append(MediaText.duration(duration)) }
        if versions.count > 1 { parts.append("\(versions.count) versions") }
        return parts.joined(separator: " · ")
    }
}
