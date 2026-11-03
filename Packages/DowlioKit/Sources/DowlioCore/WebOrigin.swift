import Foundation

public extension URL {
    /// Scheme, host and port, as a browser writes it in an `Origin` header. `nil` for a link that
    /// isn't on the web.
    var webOrigin: String? {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        let port = port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(shownHost)\(port)"
    }

    /// The `Origin` a page's player sends when it reads this link with a script from the page
    /// at `referrer`: only when the two are on different origins.
    func crossOrigin(from referrer: URL?) -> String? {
        guard let from = referrer?.webOrigin, from != webOrigin else { return nil }
        return from
    }
}
