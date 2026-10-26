import DowlioCore
import Foundation

struct Probed {
    enum Body {
        case whole(Connection)
        case ranges(total: Int64, validator: String?, firstReply: Connection?)

        var openConnection: Connection? {
            switch self {
            case .whole(let connection): connection
            case .ranges(_, _, let firstReply): firstReply
            }
        }
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

    init(changedFile response: HTTPURLResponse, over connection: Connection, requested target: URL) {
        let ranges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        guard ranges, response.isUsableRangeReply, let total = response.knownLength, total > 0 else {
            self.init(wholeFile: response, over: connection, requested: target)
            return
        }
        self.init(
            body: .ranges(total: total, validator: response.validator, firstReply: connection),
            finalURL: response.url ?? target, totalBytes: total, probeResponse: response
        )
    }

    /// Closes the probe's own connection, for a probe whose reply the download won't read.
    func cancelConnection() {
        body.openConnection?.cancel()
    }
}

struct ServerProbe: Sendable {
    let connections: ConnectionOpener

    func probe(_ target: URL) async throws -> Probed {
        try await probe(target, asking: .toEnd(from: 0))
    }

    func check(_ target: URL) async throws -> Probed {
        try await probe(target, asking: .closed(ByteRange(start: 0, end: 0)))
    }

    private func probe(_ target: URL, asking range: RangeRequest) async throws -> Probed {
        let connection = connections.open(target, range: range)
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
            guard response.isUsableRangeReply, let reply = ContentRange(response), range.isAnswered(by: reply) else {
                connection.cancel()
                return try await openWholeFile(at: finalURL)
            }
            let kept = range.readsToEnd ? connection : nil
            if kept == nil { connection.cancel() }
            return Probed(
                body: .ranges(total: reply.total, validator: response.validator, firstReply: kept),
                finalURL: finalURL,
                totalBytes: reply.total,
                probeResponse: response
            )
        case 416 where response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces) == "bytes */0":
            // An empty file has no byte 0 to send.
            connection.cancel()
            return Probed(
                body: .ranges(total: 0, validator: response.validator, firstReply: nil),
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
}
