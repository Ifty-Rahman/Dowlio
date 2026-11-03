import CoreMedia
import Foundation

public enum TrackPlacement {
    public static let allowedGap = CMTime(seconds: 5, preferredTimescale: 600)

    public static func place(_ range: CMTimeRange, against reference: CMTimeRange?) -> (at: CMTime, keeping: CMTimeRange) {
        guard let reference else { return (range.start, range) }
        let at = abs((range.start - reference.start).seconds) > allowedGap.seconds ? reference.start : range.start
        let longest = reference.end - at
        guard longest > .zero, range.duration > longest + allowedGap else { return (at, CMTimeRange(start: range.start, duration: range.duration)) }
        return (at, CMTimeRange(start: range.start, duration: longest))
    }
}
