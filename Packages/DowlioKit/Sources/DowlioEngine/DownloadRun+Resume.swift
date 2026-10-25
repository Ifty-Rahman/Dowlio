import DowlioCore
import Foundation

extension DownloadRun {
    private enum ResumeReply {
        case continues(Connection, finalURL: URL)
        case startsOver(Probed)
    }

    /// Resume's first request asks for the first missing part with `If-Range`, so the server checks
    /// the file in the request that continues it. A download that can't resume starts over as a
    /// new one.
    func revalidate(_ plan: DownloadPlan) async throws -> DownloadPlan {
        guard plan.canResume, case .ranges(let validator?) = plan.layout, let total = plan.totalBytes else {
            let probed = try await followingTheLink(of: plan) { try await probeWithRetries($0) }
            return try await startOver(plan, with: probed)
        }
        let board = plan.board
        guard let first = board.waitingSegments().first else {
            await changeSnapshot { $0.state = .downloading }
            return plan
        }
        let missing = board.missing(segment: first)

        let reply = try await followingTheLink(of: plan) { target in
            try await withRetries(.probe, host: target) {
                try await resumeReply(at: target, asking: missing, of: total, validator: validator)
            }
        }
        switch reply {
        case .continues(let connection, let finalURL):
            var kept = plan
            kept.finalURL = finalURL
            applyHostLimit(of: finalURL)
            planStore.store(kept, holding: HeldConnection(connection: connection, start: missing.start))
            await changeSnapshot { $0.state = .downloading }
            return kept
        case .startsOver(let probed):
            return try await startOver(plan, with: probed)
        }
    }

    private func resumeReply(at target: URL, asking missing: ByteRange, of total: Int64, validator: String) async throws -> ResumeReply {
        switch try await connections.askForRange(missing, of: total, ifRange: validator, at: target) {
        case .range(let connection, let response) where response.validator.map({ $0 == validator }) ?? true:
            return .continues(connection, finalURL: response.url ?? target)
        case .range(let connection, let response):
            connection.cancel()
            return .startsOver(try await probe.probe(response.url ?? target))
        case .wholeFile(let connection, let response):
            return .startsOver(Probed(changedFile: response, over: connection, requested: target))
        case .unusable(let finalURL):
            return .startsOver(try await probe.probe(finalURL ?? target))
        }
    }

    /// Signed final links expire, so Resume asks the original link first, then the last final link.
    private func followingTheLink<T>(of plan: DownloadPlan, _ ask: (URL) async throws -> T) async throws -> T {
        do {
            return try await ask(url)
        } catch let error as DownloadError where Self.meansLinkGone(error) {
            do {
                return try await ask(plan.finalURL)
            } catch let error as DownloadError where Self.meansLinkGone(error) {
                throw DownloadError.linkExpired
            }
        }
    }

    private static func meansLinkGone(_ error: DownloadError) -> Bool {
        error == .forbidden || error == .notFound
    }
}
