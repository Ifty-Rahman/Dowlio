import DowlioCore
import Foundation

struct Probed {
    enum Body {
        case whole(Connection)
        case ranges(total: Int64, validator: String?)
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
        if case .whole(let connection) = body { connection.cancel() }
    }
}

struct ServerProbe: Sendable {
    let connections: ConnectionOpener

    func probe(_ target: URL) async throws -> Probed {
        let connection = connections.open(target, range: ByteRange(start: 0, end: 0))
        let response = try await connection.firstResponse()
        switch response.statusCode {
        case 200:
            return Probed(wholeFile: response, over: connection, requested: target)
        case 206:
            connection.cancel()
            let finalURL = response.url ?? target
            guard response.isUsableRangeReply, let reply = ContentRange(response), reply.start == 0, reply.end == 0 else {
                return try await openWholeFile(at: finalURL)
            }
            return Probed(
                body: .ranges(total: reply.total, validator: response.validator),
                finalURL: finalURL,
                totalBytes: reply.total,
                probeResponse: response
            )
        case 416 where response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces) == "bytes */0":
            // An empty file has no byte 0 to send.
            connection.cancel()
            return Probed(
                body: .ranges(total: 0, validator: response.validator),
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
    func probeWithRetries(_ target: URL) async throws -> Probed {
        try await withRetries(.probe, host: target) { try await probe.probe(target) }
    }

    /// Signed final links expire, so Resume probes the original link first, then the last final link.
    func probeForResume(_ plan: DownloadPlan) async throws -> Probed {
        do {
            return try await probeWithRetries(url)
        } catch let error as DownloadError where Self.meansLinkGone(error) {
            do {
                return try await probeWithRetries(plan.finalURL)
            } catch let error as DownloadError where Self.meansLinkGone(error) {
                throw DownloadError.linkExpired
            }
        }
    }

    private static func meansLinkGone(_ error: DownloadError) -> Bool {
        error == .forbidden || error == .notFound
    }
}
