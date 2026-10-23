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
        /// the probe reply, are never held.
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

        public init(
            data: Data,
            supportsRanges: Bool = true,
            holdAfterBytes: Int? = nil,
            shortRangeBodiesBy: Int = 0,
            misreportRangeStartBy: Int = 0,
            eTag: String? = nil,
            lastModified: String? = nil
        ) {
            self.data = data
            self.supportsRanges = supportsRanges
            self.holdAfterBytes = holdAfterBytes
            self.shortRangeBodiesBy = shortRangeBodiesBy
            self.misreportRangeStartBy = misreportRangeStartBy
            self.eTag = eTag
            self.lastModified = lastModified
        }

        /// The `ETag` and `Last-Modified` headers this file's replies carry.
        var validatorHeaders: [String: String] {
            var headers: [String: String] = [:]
            if let eTag { headers["ETag"] = eTag }
            if let lastModified { headers["Last-Modified"] = lastModified }
            return headers
        }
    }

    public struct Request: Sendable {
        public let method: String
        public let path: String
        /// Header names are lowercased.
        public let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DowlioTestSupport.TestServer")
    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var redirects: [String: String] = [:]
    private var recorded: [Request] = []
    private var released = false
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
    }

    public func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public func serve(_ file: File, at path: String) {
        lock.withLock { files[path] = file }
    }

    /// Answers requests for `path` with a 302 to `target`.
    public func redirect(_ path: String, to target: String) {
        lock.withLock { redirects[path] = target }
    }

    public var requests: [Request] {
        lock.withLock { recorded }
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
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHeaders(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
        let (file, redirect): (File?, String?) = lock.withLock {
            recorded.append(request)
            return (files[request.path], redirects[request.path])
        }

        if let redirect {
            return send(status: "302 Found", headers: ["Location": redirect], body: Data(), hold: nil, on: connection)
        }

        guard let file else {
            return send(status: "404 Not Found", headers: [:], body: Data(), hold: nil, on: connection)
        }

        let total = file.data.count
        if file.supportsRanges, let range = headers["range"].flatMap({ Self.parseRange($0, total: total) }) {
            guard range.lowerBound < total else {
                return send(status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(total)"], body: Data(), hold: nil, on: connection)
            }
            var body = file.data.subdata(in: range)
            if body.count > file.shortRangeBodiesBy { body.removeLast(file.shortRangeBodiesBy) }
            send(
                status: "206 Partial Content",
                headers: file.validatorHeaders.merging([
                    "Content-Range": "bytes \(range.lowerBound + (range.count > 1 ? file.misreportRangeStartBy : 0))-\(range.upperBound - 1)/\(total)",
                    "Accept-Ranges": "bytes",
                ]) { $1 },
                body: body,
                hold: file.holdAfterBytes,
                on: connection
            )
        } else {
            send(
                status: "200 OK",
                headers: file.validatorHeaders.merging(file.supportsRanges ? ["Accept-Ranges": "bytes"] : [:]) { $1 },
                body: file.data,
                hold: file.holdAfterBytes,
                on: connection
            )
        }
    }

    private func send(status: String, headers: [String: String], body: Data, hold: Int?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        let close: @Sendable (NWError?) -> Void = { _ in connection.cancel() }
        // One-byte bodies, such as the probe reply, are never held.
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
