import DowlioCore
import Foundation

/// Runs one download: probes the server, moves the bytes into the partial file over one or more
/// connections, then puts the finished file in place.
struct DownloadRun: Sendable {
    /// Applies a change to the download's snapshot in the engine.
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    static let progressInterval: Duration = .milliseconds(250)

    let url: URL
    let folder: URL
    let options: RequestOptions
    let changeSnapshot: ChangeSnapshot

    func run() async {
        do {
            let probed = try await probe()
            let fileName = FileNaming.name(for: probed.probeResponse, finalURL: probed.finalURL)
            await changeSnapshot {
                $0.state = .downloading
                $0.fileName = fileName
                $0.totalBytes = probed.totalBytes
                $0.isNotSecure = probed.finalURL.isPlainHTTP || url.isPlainHTTP
            }

            let partial = try PartialFile.create(for: fileName, in: folder)
            let board: ProgressBoard
            switch probed.body {
            case .whole(let connection):
                let segments = probed.totalBytes.map { [ByteRange(start: 0, end: $0 - 1)] } ?? []
                board = ProgressBoard(segments: segments)
                try await reportingProgress(of: board, total: probed.totalBytes) {
                    try await receiveWhole(connection, into: partial, board: board, segmented: !segments.isEmpty)
                }
            case .ranges(let total, let validator):
                let segments = SegmentPlanner.plan(size: total, connections: options.connections)
                board = ProgressBoard(segments: segments)
                try await reportingProgress(of: board, total: total) {
                    try await receiveSegments(
                        segments, of: total, from: probed.finalURL, validator: validator,
                        into: partial, board: board
                    )
                }
            }

            let reading = board.reading
            await changeSnapshot {
                $0.apply(reading)
                $0.bytesPerSecond = 0
                $0.timeRemaining = nil
                $0.state = .finalizing
            }
            // Every byte must be present before the file goes into place.
            if let expected = probed.totalBytes,
               reading.receivedBytes != expected || (!reading.segments.isEmpty && !board.coversEverySegment) {
                throw DownloadError.incompleteFile
            }
            let finishedName = try partial.finish(named: fileName, in: folder, policy: options.nameConflictPolicy, source: url)
            await changeSnapshot { $0.fileName = finishedName; $0.state = .completed }
        } catch let error as DownloadError {
            await changeSnapshot { $0.state = .failed(error) }
        } catch {
            let description = error.localizedDescription
            await changeSnapshot { $0.state = .failed(.network(description)) }
        }
    }

    // MARK: - Receiving

    /// Reads a 200 response, which carries the whole file, into the partial file.
    private func receiveWhole(_ connection: Connection, into partial: PartialFile, board: ProgressBoard, segmented: Bool) async throws {
        if segmented { board.setActive(true, segment: 0) }
        defer { if segmented { board.setActive(false, segment: 0) } }
        for try await event in connection.events {
            if case .data(let data) = event {
                try partial.append(data)
                board.add(Int64(data.count), to: segmented ? 0 : nil)
            }
        }
    }

    /// Fetches every segment over its own connection. The first connection opens alone. The
    /// others open once it receives data, or at once in "all at once" mode.
    private func receiveSegments(
        _ segments: [ByteRange],
        of total: Int64,
        from url: URL,
        validator: String?,
        into partial: PartialFile,
        board: ProgressBoard
    ) async throws {
        let firstData = OneShot()
        try await withThrowingTaskGroup(of: Void.self) { group in
            func fetch(_ index: Int) {
                // The first connection fires the signal on its first data, or when it ends.
                let onData: @Sendable () -> Void
                if index == 0 {
                    onData = { firstData.fire() }
                } else {
                    onData = {}
                }
                group.addTask {
                    defer { if index == 0 { firstData.fire() } }
                    try await receive(
                        segment: index, range: segments[index], of: total, from: url,
                        validator: validator, into: partial, board: board, onData: onData
                    )
                }
            }

            fetch(0)
            if options.openExtraConnections == .afterFirstConnectionStarts {
                await firstData.wait()
            }
            for index in segments.indices.dropFirst() where !Task.isCancelled {
                fetch(index)
            }
            try await group.waitForAll()
        }
    }

    /// Fetches one segment and writes it at its own offset.
    private func receive(
        segment index: Int,
        range: ByteRange,
        of total: Int64,
        from url: URL,
        validator: String?,
        into partial: PartialFile,
        board: ProgressBoard,
        onData: @Sendable () -> Void
    ) async throws {
        var request = Self.request(for: url, range: range)
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let connection = Connection(request: request)
        board.setActive(true, segment: index)
        defer { board.setActive(false, segment: index) }

        let response = try await connection.firstResponse()
        guard response.statusCode == 206, ContentRange(response) == ContentRange(range: range, total: total) else {
            connection.cancel()
            throw DownloadError.rangeNotSupported
        }
        var offset = range.start
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
            try partial.write(data, at: offset)
            offset += Int64(data.count)
            board.add(Int64(data.count), to: index)
            onData()
        }
    }

    /// Runs `work` while publishing the board at most 4 times a second, also while no bytes
    /// arrive, with speed smoothed over 5 seconds and the time left.
    private func reportingProgress(of board: ProgressBoard, total: Int64?, _ work: () async throws -> Void) async throws {
        let reporter = Task {
            var meter = SpeedMeter()
            // The starting sample lets the first tick measure bytes that arrived before it.
            _ = meter.record(board.reading.receivedBytes, at: .now)
            var published: (reading: ProgressBoard.Reading, speed: Int64)?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
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
        defer { reporter.cancel() }
        try await work()
    }

    // MARK: - Probe

    private enum ProbedBody {
        /// The probe's own 200 response, which carries the whole file.
        case whole(Connection)
        /// The server supports ranges.
        case ranges(total: Int64, validator: String?)
    }

    private struct Probed {
        let body: ProbedBody
        let finalURL: URL
        let totalBytes: Int64?
        /// The probe's response, whose headers name the file.
        let probeResponse: HTTPURLResponse
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
            return Probed(body: .whole(probe), finalURL: finalURL, totalBytes: total, probeResponse: response)
        case 206:
            probe.cancel()
            guard let reply = ContentRange(response), reply.start == 0, reply.end == 0 else {
                throw DownloadError.rangeNotSupported
            }
            return Probed(
                body: .ranges(total: reply.total, validator: Self.validator(of: response)),
                finalURL: finalURL,
                totalBytes: reply.total,
                probeResponse: response
            )
        default:
            probe.cancel()
            throw DownloadError.unexpectedStatus(response.statusCode)
        }
    }

    /// A strong `ETag`, or else `Last-Modified`. A weak ETag can't be used with `If-Range`.
    private static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") {
            return tag
        }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    private static func request(for url: URL, range: ByteRange) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

extension DownloadSnapshot {
    mutating func apply(_ reading: ProgressBoard.Reading) {
        segments = reading.segments
        receivedBytes = reading.receivedBytes
        activeConnections = reading.activeConnections
    }
}

/// A signal that fires once. Waiters resume when it fires, and wait no longer after that.
final class OneShot: @unchecked Sendable {
    // @unchecked: `fired` and `waiters` are only read or written under `lock`.
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
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
