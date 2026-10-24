import DowlioCore
import Foundation

extension DownloadRun {
    func finish(_ plan: DownloadPlan) async throws {
        let reading = plan.board.reading
        await changeSnapshot {
            $0.apply(reading)
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .finalizing
        }
        saveManifest(plan)
        if let expected = plan.totalBytes, !plan.board.coversFile(of: expected) {
            throw DownloadError.incompleteFile
        }
        try Task.checkCancellation()
        let finished = try plan.partial.finish(
            named: plan.fileName, in: plan.partial.packageURL.deletingLastPathComponent(), policy: options.nameConflictPolicy, source: url
        )
        partialFile.url = nil
        await changeSnapshot {
            $0.fileName = finished.name
            $0.wasSkipped = finished.wasSkipped
            $0.state = .completed
        }
    }
}
