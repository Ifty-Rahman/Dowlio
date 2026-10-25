import DowlioCore
import Foundation

struct Probed {
    enum Body {
        case whole(Connection)
        /// `probeConnection` is still open, for a probe that asked for the whole file. Its reply is
        /// the first segment.
        case ranges(total: Int64, validator: String?, probeConnection: Connection?)
    }

    let body: Body
    let finalURL: URL
    let totalBytes: Int64?
    let probeResponse: HTTPURLResponse
}

extension Probed {
    init(wholeFile response: HTTPURLResponse, over connection: Connection, requested target: URL) {
        self.init(
            body: .whole(connection), finalURL: response.url ?? target, totalBytes: response.knownLength,
            probeResponse: response
        )
    }

    /// Closes the probe's own connection, for a probe whose reply the download won't read.
    func cancelConnection() {
        switch body {
        case .whole(let connection): connection.cancel()
        case .ranges(_, _, let probeConnection?): probeConnection.cancel()
        case .ranges: break
        }
    }
}

struct ServerProbe: Sendable {
    let connections: ConnectionOpener

    /// Like Neat Download Manager, a download's probe asks for the whole file with `bytes=0-`, and
    /// a usable range reply goes on as the first segment. A probe that only checks the server,
    /// `readsFirstSegment` false, asks for `bytes=0-0`.
    func probe(_ target: URL, readsFirstSegment: Bool) async throws -> Probed {
        let connection = readsFirstSegment
            ? connections.openFromStart(target)
            : connections.open(target, range: ByteRange(start: 0, end: 0))
        let response: HTTPURLResponse
        do {
            response = try await connection.firstResponse()
        } catch let error as URLError where error.isUndecodableBody {
            return try await openWholeFile(at: target)
        }
        switch response.statusCode {
        case 200:
            return Probed(wholeFile: response, over: connection, requested: target)
        case 206:
            let finalURL = response.url ?? target
            guard response.isUsableRangeReply, let reply = ContentRange(response), reply.start == 0,
                  reply.end == (readsFirstSegment ? reply.total - 1 : 0) else {
                connection.cancel()
                return try await openWholeFile(at: finalURL)
            }
            if !readsFirstSegment { connection.cancel() }
            return Probed(
                body: .ranges(total: reply.total, validator: response.validator, probeConnection: readsFirstSegment ? connection : nil),
                finalURL: finalURL,
                totalBytes: reply.total,
                probeResponse: response
            )
        case 416 where response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces) == "bytes */0":
            // An empty file has no byte 0 to send.
            connection.cancel()
            return Probed(
                body: .ranges(total: 0, validator: response.validator, probeConnection: nil),
                finalURL: response.url ?? target,
                totalBytes: 0,
                probeResponse: response
            )
        default:
            connection.cancel()
            throw connections.failure(for: response)
        }
    }

    func openWholeFile(at target: URL) async throws -> Probed {
        let (connection, response) = try await connections.openWholeFile(at: target)
        return Probed(wholeFile: response, over: connection, requested: target)
    }
}

extension DownloadRun {
    func probeWithRetries(_ target: URL, readsFirstSegment: Bool) async throws -> Probed {
        try await withRetries(.probe, host: target) {
            try await probe.probe(target, readsFirstSegment: readsFirstSegment)
        }
    }

    /// Signed final links expire, so Resume probes the original link first, then the last final link.
    func probeForResume(_ plan: DownloadPlan) async throws -> Probed {
        do {
            return try await probeWithRetries(url, readsFirstSegment: false)
        } catch let error as DownloadError where Self.meansLinkGone(error) {
            do {
                return try await probeWithRetries(plan.finalURL, readsFirstSegment: false)
            } catch let error as DownloadError where Self.meansLinkGone(error) {
                throw DownloadError.linkExpired
            }
        }
    }

    private static func meansLinkGone(_ error: DownloadError) -> Bool {
        error == .forbidden || error == .notFound
    }
}
