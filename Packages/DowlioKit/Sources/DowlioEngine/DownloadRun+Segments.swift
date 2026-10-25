import DowlioCore
import Foundation

extension DownloadRun {
    /// Neat Download Manager's way: one connection first, a second once the first has data,
    /// and the rest once the second has data. Each new connection splits the largest part no
    /// connection has reached yet. A refused new connection gives its part back to the segment
    /// before it, whose connection asks for that part once it finishes its own. A part left without
    /// a connection gets fetched in another round.
    func receiveSegments(_ plan: DownloadPlan, validator: String?) async throws {
        guard let total = plan.totalBytes else { return }
        var receivedBefore: Int64 = -1
        while true {
            let waiting = plan.board.waitingSegments()
            guard !waiting.isEmpty else { return }
            let received = plan.board.reading.receivedBytes
            guard received > receivedBefore else { throw RetryableFailure() }
            receivedBefore = received
            try await connect(waiting, of: plan, total: total, validator: validator)
        }
    }

    private func connect(_ waiting: [Int], of plan: DownloadPlan, total: Int64, validator: String?) async throws {
        let board = plan.board
        let waitsForData = options.openExtraConnections == .afterFirstConnectionStarts
        let firstData = OneShot()
        let secondData = OneShot()

        try await withThrowingTaskGroup(of: Void.self) { group in
            func start(_ segment: Int?, growing: Bool, onData: @escaping @Sendable () -> Void, ready: OneShot?) {
                group.addTask {
                    defer { ready?.fire() }
                    try await work(
                        from: segment, growing: growing, of: plan, total: total, validator: validator, onData: onData
                    )
                }
            }

            start(waiting[0], growing: false, onData: { firstData.fire() }, ready: firstData)
            if waitsForData { await firstData.wait() }
            for index in waiting.dropFirst() where !Task.isCancelled {
                start(index, growing: false, onData: {}, ready: nil)
            }
            let limit = min(gate.currentLimit, connectionSetting)
            func worthOpening(_ wanted: Int) -> Int {
                SegmentPlanner.connectionsWorthOpening(missing: total - board.reading.receivedBytes, wanted: wanted)
            }
            if worthOpening(limit - waiting.count) > 0, !Task.isCancelled {
                start(nil, growing: true, onData: { secondData.fire() }, ready: secondData)
                if waitsForData { await secondData.wait() }
                for _ in 0..<worthOpening(limit - waiting.count - 1) where !Task.isCancelled {
                    start(nil, growing: true, onData: {}, ready: nil)
                }
            }
            // `waitForAll` waits for every task and doesn't cancel them. Leaving the group by
            // throwing cancels the others as soon as one fails for good.
            for try await _ in group {}
        }
    }

    /// One connection's life. With no `segment` it's a new connection: it waits for a free place,
    /// then splits. When its segment is done, it splits again if stealing is on.
    private func work(
        from segment: Int?,
        growing: Bool,
        of plan: DownloadPlan,
        total: Int64,
        validator: String?,
        onData: @escaping @Sendable () -> Void
    ) async throws {
        let board = plan.board
        var current: Int
        if let segment {
            current = segment
        } else {
            guard let split = try await splitWithPlace(board, shown: growing) else { return }
            current = split
            if growing { await publishLayout(of: board) }
            guard try await firstTry(of: current, in: plan, total: total, validator: validator, onData: onData, growing: growing)
            else { return }
        }
        while true {
            if board.isUnfinished(segment: current) {
                try await withRetries(.segment(current), host: plan.finalURL) {
                    try await gate.acquire()
                    do {
                        try await receive(segment: current, of: plan, total: total, validator: validator, onData: onData)
                    } catch {
                        // Lowered as the place is given back, so a waiting connection can't take it in between.
                        gate.release(lowering: RetryableFailure(classifying: error)?.isRefusal == true)
                        throw error
                    }
                    gate.release()
                }
                continue
            }
            // A host that limits connections may not have seen a cut-short reply close yet, so a
            // steal could be refused. Finished connections close instead.
            let hostLimitsConnections = gate.currentLimit < connectionSetting
            guard options.allowsWorkStealing, !hostLimitsConnections, let split = try await splitWithPlace(board, shown: false)
            else { return }
            current = split
            guard try await firstTry(of: current, in: plan, total: total, validator: validator, onData: onData, growing: false)
            else { return }
        }
    }

    /// Waits for a free place, then splits. Gives the place back when nothing can be split. A
    /// `shown` split is part of the ramp-up, so the interface draws it.
    private func splitWithPlace(_ board: ProgressBoard, shown: Bool) async throws -> Int? {
        try await gate.acquire()
        guard let split = shown ? board.splitShown() : board.steal() else {
            gate.release()
            return nil
        }
        return split
    }

    /// A new segment's first request, with the place `splitWithPlace` took. If the host refuses it
    /// before its first byte, its part goes back to the segment before it, and this connection
    /// ends. Returns whether the connection goes on.
    private func firstTry(
        of segment: Int,
        in plan: DownloadPlan,
        total: Int64,
        validator: String?,
        onData: @escaping @Sendable () -> Void,
        growing: Bool
    ) async throws -> Bool {
        do {
            try await receive(segment: segment, of: plan, total: total, validator: validator, onData: onData)
            gate.release()
            return true
        } catch is RangesUnusable {
            gate.release()
            throw RangesUnusable()
        } catch is FileChangedOnServer {
            gate.release()
            throw FileChangedOnServer()
        } catch {
            if Task.isCancelled {
                gate.release()
                throw error
            }
            let refused = RetryableFailure(classifying: error)?.isRefusal == true
            gate.release(lowering: refused)
            if refused { lowerLimit(of: plan.finalURL, for: .segment(segment)) }
            if plan.board.received(segment: segment) == 0, plan.board.rollBack(segment: segment) {
                await publishLayout(of: plan.board)
                return false
            }
            guard RetryableFailure(classifying: error) != nil else { throw error }
            return true
        }
    }

    /// Shows the segments the ramp-up made, so the bar draws one piece per connection it opened.
    /// Read as the change applies, so a later layout never loses to an earlier one.
    private func publishLayout(of board: ProgressBoard) async {
        guard board.drawsRampUp else { return }
        await changeSnapshot { $0.plannedSegments = board.shownLayout.map { SegmentBounds(start: $0.start, end: $0.end) } }
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
        try Task.checkCancellation()

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
