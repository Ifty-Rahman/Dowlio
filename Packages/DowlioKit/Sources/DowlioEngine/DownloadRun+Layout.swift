import Foundation

extension DownloadRun {
    func layOut(_ probed: Probed, fileName: String, in partial: PartialFile) throws -> DownloadPlan {
        if let total = probed.totalBytes { try partial.reserve(bytes: total) }

        let plan: DownloadPlan
        switch probed.body {
        case .whole(let connection):
            let segments = probed.totalBytes.map { [ByteRange(start: 0, end: $0 - 1)] } ?? []
            plan = DownloadPlan(
                fileName: fileName, finalURL: probed.finalURL, totalBytes: probed.totalBytes,
                layout: .whole, segments: segments, partial: partial, board: ProgressBoard(segments: segments)
            )
            planStore.store(plan, probeConnection: connection)
        case .ranges(let total, let validator):
            let hostLimit = probed.finalURL.hostLimitKey.flatMap(configuration.hostLimits.limit(for:))
            gate.setLimit(min(options.connections, hostLimit ?? .max))
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
}
