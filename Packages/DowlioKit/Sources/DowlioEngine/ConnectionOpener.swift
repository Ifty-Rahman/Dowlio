import DowlioCore
import Foundation

struct ConnectionOpener: Sendable {
    let originalURL: URL
    let options: RequestOptions
    let idleTimeout: Duration
    let now: @Sendable () -> Date

    func open(_ url: URL, range: ByteRange?, ifRange validator: String? = nil) -> Connection {
        var request = request(for: url, range: range)
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
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

    private func request(for url: URL, range: ByteRange?) -> URLRequest {
        var request = URLRequest(url: url)
        if let range { request.setValue(range.headerValue, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referrer = options.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        if let userAgent = options.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        // Cookies came from the link's own site, and a redirect may lead to another one.
        if !options.cookies.isEmpty, url.hasSameOrigin(as: originalURL) {
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
