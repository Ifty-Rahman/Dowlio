import Foundation

extension DownloadRun {
    func receiveSegments(_ plan: DownloadPlan, validator: String?) async throws {
        let board = plan.board
        let unfinished = (0..<board.segmentCount).filter { index in
            board.received(segment: index) < board.range(segment: index).length
        }
        guard let first = unfinished.first, let total = plan.totalBytes else { return }

        let firstData = OneShot()
        try await withThrowingTaskGroup(of: Void.self) { group in
            func fetch(_ index: Int) {
                let onData: @Sendable () -> Void
                if index == first {
                    onData = { firstData.fire() }
                } else {
                    onData = {}
                }
                group.addTask {
                    defer { if index == first { firstData.fire() } }
                    var current = index
                    while true {
                        try await withRetries(.segment(current), host: plan.finalURL) {
                            try await gate.acquire()
                            do {
                                try await receive(
                                    segment: current, of: plan, total: total, validator: validator, onData: onData
                                )
                            } catch {
                                // Lowered as the place is given back, so a waiting connection can't take it in between.
                                gate.release(lowering: RetryableFailure(classifying: error)?.isRefusal == true)
                                throw error
                            }
                            gate.release()
                        }
                        guard let stolen = board.steal() else { return }
                        current = stolen
                    }
                }
            }

            fetch(first)
            if options.openExtraConnections == .afterFirstConnectionStarts {
                await firstData.wait()
            }
            for index in unfinished.dropFirst() where !Task.isCancelled {
                fetch(index)
            }
            // `waitForAll` waits for every task and doesn't cancel them. Leaving the group by
            // throwing cancels the others as soon as one fails for good.
            for try await _ in group {}
        }
    }

    private func receive(
        segment index: Int,
        of plan: DownloadPlan,
        total: Int64,
        validator: String?,
        onData: @Sendable () -> Void
    ) async throws {
        let board = plan.board
        let segment = board.range(segment: index)
        let missing = ByteRange(start: segment.start + board.received(segment: index), end: segment.end)
        guard missing.start <= missing.end else { return }

        let connection = connections.open(plan.finalURL, range: missing, ifRange: validator)
        board.setActive(true, segment: index)
        defer { board.setActive(false, segment: index) }

        let response: HTTPURLResponse
        do {
            response = try await connection.firstResponse()
        } catch let error as URLError where error.code == .cannotDecodeRawData || error.code == .cannotDecodeContentData {
            // URLSession fails to decode an encoded reply before it hands over the response.
            throw RangesUnusable()
        }
        guard response.statusCode == 206 else {
            connection.cancel()
            guard response.statusCode == 200 else { throw connections.failure(for: response) }
            // A 200 to If-Range means the validator no longer matches (RFC 9110). Without a
            // validator, the server ignored the range.
            throw validator == nil ? RangesUnusable() : FileChangedOnServer()
        }
        guard response.isUsableRangeReply, ContentRange(response) == ContentRange(range: missing, total: total) else {
            connection.cancel()
            throw RangesUnusable()
        }
        var offset = missing.start
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
            let allowed = board.claim(Int64(data.count), at: offset, segment: index)
            if allowed > 0 {
                try plan.partial.write(data.prefix(Int(allowed)), at: offset)
                offset += allowed
                board.add(allowed, to: index)
                onData()
            }
            if allowed < Int64(data.count) || offset > board.range(segment: index).end {
                connection.cancel()
                return
            }
        }
        try RetryableFailure.throwIfEndedEarly(received: offset, expected: board.range(segment: index).end + 1)
    }
}
