import DowlioCore
import Foundation

/// Runs one download: probes the server, moves the bytes into the partial file, then puts the
/// finished file in place.
struct DownloadRun: Sendable {
    /// Applies a change to the download's snapshot in the engine.
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    static let progressInterval: Duration = .milliseconds(250)

    let url: URL
    let folder: URL
    let options: RequestOptions
    let partialFile: PartialFileLocation
    let changeSnapshot: ChangeSnapshot

    func run() async {
        do {
            let probed = try await probe()
            let fileName = FileNaming.name(for: probed.finalURL)
            await changeSnapshot {
                $0.state = .downloading
                $0.fileName = fileName
                $0.totalBytes = probed.totalBytes
            }

            // The space is reserved before any of the file's bytes are requested.
            let partial = try PartialFile.create(for: fileName, in: folder)
            partialFile.url = partial.packageURL
            if let total = probed.totalBytes { try partial.reserve(bytes: total) }
            let body = try await openBody(after: probed)
            let count = try await receive(body, into: partial)
            await changeSnapshot { $0.receivedBytes = count; $0.state = .finalizing }

            // Every byte must be present before the file goes into place.
            if let expected = body.totalBytes, count != expected {
                throw DownloadError.incompleteFile
            }
            try Task.checkCancellation()
            try partial.finish(as: folder.appending(path: fileName))
            partialFile.url = nil
            await changeSnapshot { $0.state = .completed }
        } catch where Task.isCancelled {
            // Cancelled by the engine, which deletes the partial file and reports Cancelled.
        } catch let error as DownloadError {
            await changeSnapshot { $0.state = .failed(error) }
        } catch {
            let description = error.localizedDescription
            await changeSnapshot { $0.state = .failed(.network(description)) }
        }
    }

    /// Writes the body into the partial file and returns the byte count. Publishes progress at
    /// most 4 times a second, also while no bytes arrive.
    private func receive(_ body: Body, into partial: PartialFile) async throws -> Int64 {
        let received = ByteCounter()
        let reporter = Task {
            var published: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                let count = received.value
                if count != published {
                    published = count
                    await changeSnapshot { $0.receivedBytes = count }
                }
            }
        }
        defer { reporter.cancel() }

        for try await event in body.connection.events {
            if case .data(let data) = event {
                try partial.append(data)
                received.add(Int64(data.count))
            }
        }
        return received.value
    }

    /// The connection that carries the file's bytes, already past its response.
    private struct Body {
        let connection: Connection
        let totalBytes: Int64?
    }

    /// What the probe learned about the file.
    private struct Probed {
        let finalURL: URL
        let totalBytes: Int64?
        /// The probe's own connection, when the server ignored the range and sent the whole file.
        let wholeFile: Connection?
    }

    /// Sends `Range: bytes=0-0` (architecture.md, probe). A 206 means the server supports ranges
    /// and gives the size. A 200 means it doesn't, and the probe's own response is the download.
    private func probe() async throws -> Probed {
        let probe = Connection(request: Self.request(for: url, range: ByteRange(start: 0, end: 0)))
        let response = try await probe.firstResponse()
        let finalURL = response.url ?? url
        switch response.statusCode {
        case 200:
            let total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            return Probed(finalURL: finalURL, totalBytes: total, wholeFile: probe)
        case 206:
            probe.cancel()
            guard let reply = ContentRange(response), reply.start == 0, reply.end == 0 else {
                throw DownloadError.rangeNotSupported
            }
            return Probed(finalURL: finalURL, totalBytes: reply.total, wholeFile: nil)
        default:
            probe.cancel()
            throw DownloadError.unexpectedStatus(response.statusCode)
        }
    }

    /// The connection for the file's bytes: the probe's own, or a new request for the whole range.
    private func openBody(after probed: Probed) async throws -> Body {
        if let wholeFile = probed.wholeFile {
            return Body(connection: wholeFile, totalBytes: probed.totalBytes)
        }
        guard let total = probed.totalBytes else { throw DownloadError.rangeNotSupported }
        let whole = ByteRange(start: 0, end: total - 1)
        let connection = Connection(request: Self.request(for: probed.finalURL, range: whole))
        let response = try await connection.firstResponse()
        guard response.statusCode == 206 else {
            connection.cancel()
            throw DownloadError.unexpectedStatus(response.statusCode)
        }
        guard ContentRange(response) == ContentRange(range: whole, total: total) else {
            connection.cancel()
            throw DownloadError.rangeNotSupported
        }
        return Body(connection: connection, totalBytes: total)
    }

    private static func request(for url: URL, range: ByteRange) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

/// An inclusive byte range, as HTTP writes it.
struct ByteRange: Equatable {
    let start: Int64
    let end: Int64

    /// The `Range` request header value.
    var headerValue: String { "bytes=\(start)-\(end)" }
}

/// A parsed `Content-Range: bytes start-end/total` header.
struct ContentRange: Equatable {
    let range: ByteRange
    let total: Int64

    var start: Int64 { range.start }
    var end: Int64 { range.end }

    init(range: ByteRange, total: Int64) {
        self.range = range
        self.total = total
    }

    init?(_ response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        self.init(value)
    }

    init?(_ value: String) {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start <= end, end < total else { return nil }
        self.init(range: ByteRange(start: start, end: end), total: total)
    }
}

/// A byte count shared between a download and its progress reporter.
final class ByteCounter: @unchecked Sendable {
    // @unchecked: `count` is only read or written under `lock`.
    private let lock = NSLock()
    private var count: Int64 = 0

    var value: Int64 { lock.withLock { count } }

    func add(_ bytes: Int64) {
        lock.withLock { count += bytes }
    }
}
