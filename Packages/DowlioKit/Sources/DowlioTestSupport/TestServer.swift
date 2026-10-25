import Foundation
import Network

/// A loopback HTTP/1.1 server for engine tests. It serves files from memory, can switch range
/// support off per file, and records every request it receives. Each response closes its connection.
public final class TestServer: @unchecked Sendable {
    public struct File: Sendable {
        public var data: Data
        public var supportsRanges: Bool
        /// When set, every response for this file stops after this many body bytes until
        /// `releaseHeldResponses()` is called. Zero holds the whole body. One-byte bodies, such as
        /// a resume's probe reply, are never held. The reply to `bytes=0-` always sends its first
        /// 512 bytes, since URLSession hands over a response only once that many arrive.
        public var holdAfterBytes: Int?
        /// A broken server: range replies keep their `Content-Range` but carry this many fewer
        /// bytes, with a matching `Content-Length`.
        public var shortRangeBodiesBy: Int
        /// A broken server: replies to ranges longer than one byte claim to start this many bytes
        /// later than they do. The one-byte probe reply stays correct.
        public var misreportRangeStartBy: Int
        /// Sent as the `ETag` header on every reply, when set.
        public var eTag: String?
        /// Sent as the `Last-Modified` header on every reply, when set.
        public var lastModified: String?
        /// Extra headers sent with every 200 and 206 reply, such as `Content-Disposition` or
        /// `Content-Type`.
        public var headers: [String: String]
        /// Answers the first requests for this file with an error status instead of the file.
        public var failFirst: StatusFault?
        /// Drops the connection partway through the first replies whose body is long enough.
        public var dropFirst: BodyFault?
        /// Sends part of the first replies whose body is long enough, then nothing more, keeping
        /// the connection open.
        public var stallFirst: BodyFault?
        /// The file on the server changes after this many requests for it have been answered.
        public var changeAfter: FileChange?
        /// Every reply carries a new `ETag`, as if the file changed between any two requests.
        public var newETagEveryRequest: Bool
        /// Replies to ranges that start at this offset trickle out at this speed.
        public var throttle: RangeThrottle?
        /// At most this many replies for this file are in flight at once. Requests beyond it get
        /// a 503, as from a server that limits parallel connections. The one-byte probe request
        /// isn't counted. A reply the client stops reading early, as after a steal, stays in
        /// flight until the server's send to it ends.
        public var maxParallel: Int?
        /// Extra headers sent with every 206 reply only, such as a `Content-Encoding` that a range
        /// reply must not have.
        public var rangeReplyHeaders: [String: String]
        /// Whether `rangeReplyHeaders` also go on the probe's reply, `bytes=0-` or `bytes=0-0`, or
        /// only on the replies to segment requests.
        public var rangeReplyHeadersOnProbe: Bool
        /// A broken server: it answers the probe's range, `bytes=0-` or `bytes=0-0`, but ignores
        /// every other range and sends the whole file with 200.
        public var ignoresSegmentRanges: Bool
        /// Limits `misreportRangeStartBy` to replies for ranges that start at this offset or later.
        public var misreportOnlyRangesFrom: Int?
        /// A host that sends at most this many bytes for any range, and says so in `Content-Range`.
        public var maxRangeReplyBytes: Int?
        /// A streamed or generated file: every reply is a 200 with the whole file, no
        /// `Content-Length`, and a body that ends when the server closes the connection. Ranges
        /// are ignored.
        public var omitsLength: Bool
        public var requiredCookie: String?
        /// Only a POST with exactly this body gets the file. Anything else gets a 405.
        public var requiredForm: Data?

        public init(
            data: Data,
            supportsRanges: Bool = true,
            holdAfterBytes: Int? = nil,
            shortRangeBodiesBy: Int = 0,
            misreportRangeStartBy: Int = 0,
            eTag: String? = nil,
            lastModified: String? = nil,
            headers: [String: String] = [:],
            failFirst: StatusFault? = nil,
            dropFirst: BodyFault? = nil,
            stallFirst: BodyFault? = nil,
            changeAfter: FileChange? = nil,
            newETagEveryRequest: Bool = false,
            throttle: RangeThrottle? = nil,
            maxParallel: Int? = nil,
            rangeReplyHeaders: [String: String] = [:],
            rangeReplyHeadersOnProbe: Bool = true,
            ignoresSegmentRanges: Bool = false,
            misreportOnlyRangesFrom: Int? = nil,
            maxRangeReplyBytes: Int? = nil,
            omitsLength: Bool = false,
            requiredCookie: String? = nil,
            requiredForm: Data? = nil
        ) {
            self.requiredCookie = requiredCookie
            self.requiredForm = requiredForm
            self.omitsLength = omitsLength
            self.misreportOnlyRangesFrom = misreportOnlyRangesFrom
            self.maxRangeReplyBytes = maxRangeReplyBytes
            self.ignoresSegmentRanges = ignoresSegmentRanges
            self.maxParallel = maxParallel
            self.rangeReplyHeaders = rangeReplyHeaders
            self.rangeReplyHeadersOnProbe = rangeReplyHeadersOnProbe
            self.throttle = throttle
            self.changeAfter = changeAfter
            self.newETagEveryRequest = newETagEveryRequest
            self.data = data
            self.supportsRanges = supportsRanges
            self.holdAfterBytes = holdAfterBytes
            self.shortRangeBodiesBy = shortRangeBodiesBy
            self.misreportRangeStartBy = misreportRangeStartBy
            self.eTag = eTag
            self.lastModified = lastModified
            self.headers = headers
            self.failFirst = failFirst
            self.dropFirst = dropFirst
            self.stallFirst = stallFirst
        }

        /// The `ETag` and `Last-Modified` headers this file's replies carry.
        var validatorHeaders: [String: String] {
            var headers: [String: String] = [:]
            if let eTag { headers["ETag"] = eTag }
            if let lastModified { headers["Last-Modified"] = lastModified }
            return headers
        }
    }

    /// A new version of a file: its bytes and `ETag` after `requests` requests were answered.
    public struct FileChange: Sendable {
        public var requests: Int
        public var data: Data
        public var eTag: String

        public init(afterRequests requests: Int, data: Data, eTag: String) {
            self.requests = requests
            self.data = data
            self.eTag = eTag
        }
    }

    /// Answers `count` requests with `status` and `headers`. `Int.max` answers every request.
    public struct StatusFault: Sendable {
        public var status: Int
        public var count: Int
        public var headers: [String: String]

        public init(status: Int, count: Int = .max, headers: [String: String] = [:]) {
            self.status = status
            self.count = count
            self.headers = headers
        }
    }

    /// Cuts `count` replies after `afterBytes` body bytes. Only replies whose body is longer than
    /// `afterBytes` count, so the one-byte probe reply is never cut.
    public struct BodyFault: Sendable {
        public var afterBytes: Int
        public var count: Int

        public init(afterBytes: Int, count: Int) {
            self.afterBytes = afterBytes
            self.count = count
        }
    }

    /// Slows the replies to ranges that start at `rangeStart` to `bytesPerSecond`.
    /// Slows replies for the range that starts at `rangeStart`, or with `andLater`, for every range
    /// that starts there or later.
    public struct RangeThrottle: Sendable {
        public var rangeStart: Int
        public var bytesPerSecond: Int
        public var andLater: Bool

        public init(rangeStart: Int, bytesPerSecond: Int, andLater: Bool = false) {
            self.rangeStart = rangeStart
            self.bytesPerSecond = bytesPerSecond
            self.andLater = andLater
        }

        func slows(rangeStartingAt start: Int) -> Bool {
            andLater ? start >= rangeStart : start == rangeStart
        }
    }

    /// How a reply's body is cut short.
    private enum Cut {
        case drop(after: Int)
        case stall(after: Int)
    }

    /// Faults already used for one path.
    private struct UsedFaults {
        var status = 0
        var drop = 0
        var stall = 0
    }

    public struct Request: Sendable {
        public let method: String
        public let path: String
        /// Header names are lowercased.
        public let headers: [String: String]
        public let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DowlioTestSupport.TestServer")
    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var redirects: [String: String] = [:]
    private var usedFaults: [String: UsedFaults] = [:]
    /// Requests answered per path, for faults that change the file after a number of requests.
    private var servedCount: [String: Int] = [:]
    /// Stalled connections stay open until the server goes away.
    private var stalled: [NWConnection] = []
    private var recorded: [Request] = []
    /// Replies in flight per path, the most there ever were, and the 503s `maxParallel` sent.
    private var inFlight: [String: Int] = [:]
    private var peakInFlight: [String: Int] = [:]
    private var refusedCount: [String: Int] = [:]
    private var released = false
    private var openCount: [String: Int] = [:]
    private var heldSends: [@Sendable () -> Void] = []

    public private(set) var port: UInt16 = 0

    public init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let listener = self.listener
        let queue = self.queue
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
        stalled.forEach { $0.cancel() }
    }

    public func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public func serve(_ file: File, at path: String) {
        lock.withLock { files[path] = file }
    }

    /// Stops serving `path`, as a file or as a redirect. Later requests for it get a 404.
    public func remove(_ path: String) {
        lock.withLock {
            files[path] = nil
            redirects[path] = nil
        }
    }

    /// Answers requests for `path` with a 302 to `target`.
    public func redirect(_ path: String, to target: String) {
        lock.withLock { redirects[path] = target }
    }

    public var requests: [Request] {
        lock.withLock { recorded }
    }

    /// How many requests for `path` got a 503 because `maxParallel` replies were in flight.
    public func refusals(at path: String) -> Int {
        lock.withLock { refusedCount[path, default: 0] }
    }

    /// The most replies for `path` that were ever in flight at once.
    public func peakParallel(at path: String) -> Int {
        lock.withLock { peakInFlight[path, default: 0] }
    }

    /// How many connections that asked for `path` are still open: neither the server nor the
    /// client has closed them yet.
    public func openConnections(at path: String) -> Int {
        lock.withLock { openCount[path, default: 0] }
    }

    /// Lets every held response, and every later one, send the rest of its body.
    public func releaseHeldResponses() {
        let sends: [@Sendable () -> Void] = lock.withLock {
            released = true
            defer { heldSends = [] }
            return heldSends
        }
        sends.forEach { $0() }
    }

    /// Deterministic bytes, so tests can compare hashes against a known source.
    public static func makeData(size: Int, seed: UInt64 = 1) -> Data {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return Data(bytes)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeaders(on: connection, buffer: Data())
    }

    private func readHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = Self.contentLength(in: head)
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    self.respond(to: head, body: Data(body.prefix(length)), on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.readHeaders(on: connection, buffer: buffer)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHeaders(on: connection, buffer: buffer)
            }
        }
    }

    private static func contentLength(in head: String) -> Int {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func respond(to head: String, body: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
        let (file, redirect): (File?, String?) = lock.withLock {
            recorded.append(request)
            return (files[request.path], redirects[request.path])
        }
        watchClose(of: connection, for: request.path)

        if let redirect {
            return send(status: "302 Found", headers: ["Location": redirect], body: Data(), hold: nil, on: connection)
        }

        guard var file else {
            return send(status: "404 Not Found", headers: [:], body: Data(), hold: nil, on: connection)
        }

        if let cookie = file.requiredCookie, !(headers["cookie"] ?? "").split(separator: ";").contains(where: { $0.trimmingCharacters(in: .whitespaces) == cookie }) {
            return send(status: "401 Unauthorized", headers: [:], body: Data(), hold: nil, on: connection)
        }

        if let form = file.requiredForm, request.method != "POST" || request.body != form {
            return send(status: "405 Method Not Allowed", headers: [:], body: Data(), hold: nil, on: connection)
        }

        if let fault = file.failFirst, takeFault(\.status, at: request.path, limit: fault.count) {
            return send(status: "\(fault.status) Fault", headers: fault.headers, body: Data(), hold: nil, on: connection)
        }

        // A reply stays in flight until the server closes its connection. The count goes down
        // before the close, so a client never sees the close before the server allows a new reply.
        var leave: @Sendable () -> Void = {}
        // The one-byte probe of a resume doesn't count: its reply ends at once, but the client may
        // already open its segment connections before this server sees the probe's connection close.
        if let cap = file.maxParallel, headers["range"] != "bytes=0-0" {
            let path = request.path
            let admitted: Bool = lock.withLock {
                guard inFlight[path, default: 0] < cap else {
                    refusedCount[path, default: 0] += 1
                    return false
                }
                inFlight[path, default: 0] += 1
                peakInFlight[path] = max(peakInFlight[path, default: 0], inFlight[path]!)
                return true
            }
            guard admitted else {
                return send(status: "503 Service Unavailable", headers: [:], body: Data(), hold: nil, on: connection)
            }
            let left = LockedFlag()
            leave = { [weak self] in
                guard let self, left.set() else { return }
                self.lock.withLock { self.inFlight[path, default: 1] -= 1 }
            }
        }

        let served: Int = lock.withLock {
            servedCount[request.path, default: 0] += 1
            return servedCount[request.path]!
        }
        if let change = file.changeAfter, served > change.requests {
            file.data = change.data
            file.eTag = change.eTag
        }
        if file.newETagEveryRequest {
            file.eTag = "\"r\(served)\""
        }

        // RFC 9110 If-Range: a validator that no longer matches gets the whole file, with 200.
        let rangeHeader: String? = {
            guard let range = headers["range"] else { return nil }
            guard let ifRange = headers["if-range"] else { return range }
            return ifRange == file.eTag || ifRange == file.lastModified ? range : nil
        }()

        let total = file.data.count
        let isProbe = rangeHeader == "bytes=0-" || rangeHeader == "bytes=0-0"
        let honoured = rangeHeader.flatMap { Self.parseRange($0, total: total) }.flatMap { range in
            file.ignoresSegmentRanges && !isProbe ? nil : range
        }.map { range in
            file.maxRangeReplyBytes.map { range.prefix($0) } ?? range
        }
        if file.supportsRanges, !file.omitsLength, let range = honoured {
            guard range.lowerBound < total else {
                return send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(total)"], body: Data(), hold: nil, on: connection)
            }
            var body = file.data.subdata(in: range)
            if body.count > file.shortRangeBodiesBy { body.removeLast(file.shortRangeBodiesBy) }
            let cut = cut(for: file, at: request.path, bodyCount: body.count)
            let slow = file.throttle.flatMap { $0.slows(rangeStartingAt: range.lowerBound) ? $0.bytesPerSecond : nil }
            let misreported = range.count > 1 && range.lowerBound >= (file.misreportOnlyRangesFrom ?? range.lowerBound)
            let shift = misreported ? file.misreportRangeStartBy : 0
            send(
                status: "206 Partial Content",
                headers: file.validatorHeaders.merging([
                    "Content-Range": "bytes \(range.lowerBound + shift)-\(range.upperBound - 1)/\(total)",
                    "Accept-Ranges": "bytes",
                ].merging(file.headers) { current, _ in current }) { $1 }
                    .merging(!isProbe || file.rangeReplyHeadersOnProbe ? file.rangeReplyHeaders : [:]) { $1 },
                body: body,
                hold: rangeHeader == "bytes=0-" ? file.holdAfterBytes.map { max($0, 512) } : file.holdAfterBytes,
                cut: cut,
                bytesPerSecond: slow,
                onClose: leave,
                on: connection
            )
        } else {
            let cut = cut(for: file, at: request.path, bodyCount: file.data.count)
            send(
                status: "200 OK",
                headers: file.validatorHeaders
                    .merging(file.supportsRanges ? ["Accept-Ranges": "bytes"] : [:]) { $1 }
                    .merging(file.headers) { current, _ in current },
                body: file.data,
                hold: file.holdAfterBytes,
                cut: cut,
                sendsLength: !file.omitsLength,
                onClose: leave,
                on: connection
            )
        }
    }

    private func watchClose(of connection: NWConnection, for path: String) {
        lock.withLock { openCount[path, default: 0] += 1 }
        let closed = LockedFlag()
        let close: @Sendable () -> Void = { [weak self] in
            guard let self, closed.set() else { return }
            self.lock.withLock { self.openCount[path, default: 1] -= 1 }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed: close()
            default: break
            }
        }
        waitForEnd(of: connection, then: close)
    }

    /// The client sends nothing after its request, so a receive ends only when it goes away.
    private func waitForEnd(of connection: NWConnection, then close: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                close()
            } else {
                self?.waitForEnd(of: connection, then: close)
            }
        }
    }

    /// Uses one fault of `kind` for `path` if fewer than `limit` were used. Returns whether it did.
    private func takeFault(_ kind: WritableKeyPath<UsedFaults, Int>, at path: String, limit: Int) -> Bool {
        lock.withLock {
            var used = usedFaults[path] ?? UsedFaults()
            guard used[keyPath: kind] < limit else { return false }
            used[keyPath: kind] += 1
            usedFaults[path] = used
            return true
        }
    }

    private func cut(for file: File, at path: String, bodyCount: Int) -> Cut? {
        if let drop = file.dropFirst, bodyCount > drop.afterBytes, takeFault(\.drop, at: path, limit: drop.count) {
            return .drop(after: drop.afterBytes)
        }
        if let stall = file.stallFirst, bodyCount > stall.afterBytes, takeFault(\.stall, at: path, limit: stall.count) {
            return .stall(after: stall.afterBytes)
        }
        return nil
    }

    private func send(
        status: String,
        headers: [String: String],
        body: Data,
        hold: Int?,
        cut: Cut? = nil,
        bytesPerSecond: Int? = nil,
        sendsLength: Bool = true,
        onClose: @escaping @Sendable () -> Void = {},
        on connection: NWConnection
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        // Without `Content-Length`, the body ends where the server closes the connection.
        if sendsLength { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        let close: @Sendable (NWError?) -> Void = { _ in
            onClose()
            connection.cancel()
        }
        switch cut {
        case .drop(let after):
            // The connection closes before the body that `Content-Length` promised is complete.
            connection.send(content: Data(head.utf8) + body.prefix(after), completion: .contentProcessed(close))
            return
        case .stall(let after):
            // A stalled reply stays in flight until the server goes away.
            connection.send(content: Data(head.utf8) + body.prefix(after), completion: .contentProcessed { _ in })
            lock.withLock { stalled.append(connection) }
            return
        case nil:
            break
        }
        if let bytesPerSecond {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            trickle(body, at: bytesPerSecond, on: connection, onClose: onClose)
            return
        }
        // One-byte bodies, such as a resume's probe reply, are never held.
        guard let hold, hold < body.count, body.count > 1 else {
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed(close))
            return
        }

        let rest = body.subdata(in: hold..<body.count)
        connection.send(content: Data(head.utf8) + body.prefix(hold), completion: .contentProcessed { _ in })
        let sendRest: @Sendable () -> Void = {
            connection.send(content: rest, completion: .contentProcessed(close))
        }
        let sendNow: Bool = lock.withLock {
            if released { return true }
            heldSends.append(sendRest)
            return false
        }
        if sendNow { sendRest() }
    }

    /// Sends `body` in 16 KB pieces spaced to `bytesPerSecond`, until it's sent or the client
    /// goes away.
    private func trickle(_ body: Data, at bytesPerSecond: Int, on connection: NWConnection, onClose: @escaping @Sendable () -> Void) {
        let piece = 16 * 1024
        guard !body.isEmpty else {
            onClose()
            return connection.cancel()
        }
        let chunk = body.prefix(piece)
        let rest = body.dropFirst(piece)
        let pause = Double(chunk.count) / Double(bytesPerSecond)
        let queue = self.queue
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, !rest.isEmpty else {
                onClose()
                return connection.cancel()
            }
            queue.asyncAfter(deadline: .now() + pause) { [weak self] in
                self?.trickle(Data(rest), at: bytesPerSecond, on: connection, onClose: onClose)
            }
        })
    }

    /// Parses `bytes=a-b` and `bytes=a-`. Returns a half-open range clamped to the file.
    static func parseRange(_ value: String, total: Int) -> Range<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]) else { return nil }
        // A start beyond the file yields an empty range, which the caller answers with 416.
        if start >= total { return start..<start }
        let end = bounds[1].isEmpty ? total - 1 : min(Int(bounds[1]) ?? total - 1, total - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}

/// A flag that can be set once, safely from any thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns `true` only for the first caller.
    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}
