import DowlioCore
import Foundation

struct ConnectionOpener: Sendable {
    let originalURL: URL
    let options: RequestOptions
    let idleTimeout: Duration
    let now: @Sendable () -> Date
    let shared: SharedSession?

    init(
        originalURL: URL,
        options: RequestOptions,
        idleTimeout: Duration,
        sessions: SessionMode,
        now: @escaping @Sendable () -> Date
    ) {
        self.originalURL = originalURL
        self.options = options
        self.idleTimeout = idleTimeout
        self.now = now
        shared = sessions == .oneShared ? SharedSession(idleTimeout: idleTimeout) : nil
    }

    func open(_ url: URL, range: ByteRange?, ifRange validator: String? = nil) -> Connection {
        var request = request(for: url, range: range?.headerValue)
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        return start(request)
    }

    func openFromStart(_ url: URL) -> Connection {
        start(request(for: url, range: "bytes=0-"))
    }

    private func start(_ request: URLRequest) -> Connection {
        if let shared { return Connection(request: request, shared: shared) }
        return Connection(request: request, idleTimeout: idleTimeout)
    }

    func openWholeFile(at url: URL) async throws -> (connection: Connection, response: HTTPURLResponse) {
        let connection = open(url, range: nil)
        let response = try await connection.firstResponse()
        guard response.statusCode == 200 else {
            connection.cancel()
            throw failure(for: response)
        }
        return (connection, response)
    }

    func failure(for response: HTTPURLResponse) -> Error {
        response.failure(now: now())
    }

    private func request(for url: URL, range: String?) -> URLRequest {
        var request = URLRequest(url: url)
        let fromLinkSite = url.hasSameOrigin(as: originalURL)
        if let browserRequest = options.browserRequest, fromLinkSite {
            for header in browserRequest.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
            if url == originalURL {
                request.httpMethod = browserRequest.method
                request.httpBody = browserRequest.body
            }
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referrer = options.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        if let userAgent = options.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        // Cookies came from the link's own site, and a redirect may lead to another one.
        if !options.cookies.isEmpty, fromLinkSite {
            let cookies = options.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}

extension URL {
    /// Same scheme, host and port, with a missing port read as the scheme's default.
    func hasSameOrigin(as other: URL) -> Bool {
        guard let scheme = scheme?.lowercased(), let host = host()?.lowercased(),
              let otherHost = other.host()?.lowercased() else { return false }
        return scheme == other.scheme?.lowercased() && host == otherHost && effectivePort == other.effectivePort
    }

    private var effectivePort: Int? {
        port ?? (scheme?.lowercased() == "https" ? 443 : scheme?.lowercased() == "http" ? 80 : nil)
    }
}
