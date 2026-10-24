import Foundation

extension DownloadRun {
    func layOut(_ probed: Probed, fileName: String, in partial: PartialFile) throws -> DownloadPlan {
        if let total = probed.totalBytes, total > 0 { try partial.reserve(bytes: total) }

        let plan: DownloadPlan
        switch probed.body {
        case .whole(let connection):
            let segments = probed.totalBytes.flatMap { $0 > 0 ? [ByteRange(start: 0, end: $0 - 1)] : nil } ?? []
            plan = DownloadPlan(
                fileName: fileName, finalURL: probed.finalURL, totalBytes: probed.totalBytes,
                layout: .whole, segments: segments, partial: partial, board: ProgressBoard(segments: segments)
            )
            planStore.store(plan, probeConnection: connection)
        case .ranges(let total, let validator):
            let hostLimit = applyHostLimit(of: probed.finalURL)
            let segments = SegmentPlanner.plan(size: total, connections: options.connections, hostLimit: hostLimit)
            plan = DownloadPlan(
                fileName: fileName, finalURL: probed.finalURL, totalBytes: total,
                layout: .ranges(validator: validator), segments: segments, partial: partial,
                board: ProgressBoard(segments: segments)
            )
            planStore.store(plan, probeConnection: nil)
        }
        return plan
    }

    /// Lets the download open as many connections at once as its setting and the host's learned
    /// limit allow, and returns that limit.
    @discardableResult
    func applyHostLimit(of url: URL) -> Int? {
        let hostLimit = url.hostLimitKey.flatMap(configuration.hostLimits.limit(for:))
        gate.setLimit(min(connectionSetting, hostLimit ?? .max))
        return hostLimit
    }
}
