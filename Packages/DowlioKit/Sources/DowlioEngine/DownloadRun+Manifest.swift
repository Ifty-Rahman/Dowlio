import Foundation

extension DownloadRun {
    /// The counts are read before the data file is flushed, so they never lead the bytes on disk.
    func saveManifest(_ plan: DownloadPlan) {
        let reading = plan.board.reading
        let (layout, validator): (PartialFileManifest.Layout, String?) = switch plan.layout {
        case .whole: (.whole, nil)
        case .ranges(let validator): (.ranges, validator)
        }
        let manifest = PartialFileManifest(
            formatVersion: PartialFileManifest.currentFormatVersion,
            downloadID: id.description,
            originalURL: url,
            finalURL: plan.finalURL,
            validator: validator,
            totalBytes: plan.totalBytes,
            fileName: plan.fileName,
            connections: options.connections,
            referrer: options.referrer,
            userAgent: options.userAgent,
            segments: reading.segments.map { .init(start: $0.start, end: $0.end, received: $0.receivedBytes) },
            layout: layout
        )
        try? plan.partial.saveManifest(manifest)
    }
}
