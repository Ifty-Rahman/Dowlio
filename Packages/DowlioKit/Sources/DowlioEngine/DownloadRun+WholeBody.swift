import Foundation

extension DownloadRun {
    /// The server can't resume a whole body, so every retry starts the file over.
    func receiveWhole(_ plan: DownloadPlan) async throws {
        let board = plan.board
        let segmented = !plan.segments.isEmpty
        try await withRetries(.whole, host: plan.finalURL) {
            let connection: Connection
            if let held = planStore.takeConnection(startingAt: 0) {
                connection = held
            } else {
                try plan.partial.discardData()
                board.reset()
                if let total = plan.totalBytes { try plan.partial.reserve(bytes: total) }
                connection = try await connections.openWholeFile(at: plan.finalURL).connection
            }

            if segmented { board.setActive(true, segment: 0) }
            defer { if segmented { board.setActive(false, segment: 0) } }
            for try await event in connection.events {
                if case .data(let data) = event {
                    try plan.partial.append(data)
                    board.add(Int64(data.count), to: segmented ? 0 : nil)
                }
            }
            try RetryableFailure.throwIfEndedEarly(received: board.reading.receivedBytes, expected: plan.totalBytes)
        }
    }
}
