import DowlioCore
import Foundation

extension DownloadRun {
    static let progressInterval: Duration = .milliseconds(250)
    static let ticksPerManifestSave = 4

    func reportingProgress(of plan: DownloadPlan, _ work: () async throws -> Void) async throws {
        let board = plan.board
        let total = plan.totalBytes
        let reporter = Task {
            var meter = SpeedMeter()
            _ = meter.record(board.reading.receivedBytes, at: .now)
            var published: (reading: ProgressBoard.Reading, speed: Int64)?
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                ticks += 1
                if ticks.isMultiple(of: Self.ticksPerManifestSave) { saveManifest(plan) }
                let reading = board.reading
                let speed = meter.record(reading.receivedBytes, at: .now)
                if let published, published.reading == reading, published.speed == speed { continue }
                published = (reading, speed)
                let remaining: TimeInterval? = total.flatMap { total in
                    speed > 0 ? TimeInterval(total - reading.receivedBytes) / TimeInterval(speed) : nil
                }
                await changeSnapshot {
                    $0.apply(reading)
                    $0.bytesPerSecond = speed
                    $0.timeRemaining = remaining
                }
            }
        }
        // The reporter ends before this returns, so none of its snapshots can follow the state
        // the download moves to next.
        do {
            try await work()
        } catch {
            reporter.cancel()
            await reporter.value
            throw error
        }
        reporter.cancel()
        await reporter.value
    }
}

extension DownloadSnapshot {
    mutating func apply(_ reading: ProgressBoard.Reading) {
        segments = reading.segments
        receivedBytes = reading.receivedBytes
        activeConnections = reading.activeConnections
    }
}
