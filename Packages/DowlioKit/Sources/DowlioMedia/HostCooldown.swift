import Foundation

public actor HostCooldown {
    private var until: [String: ContinuousClock.Instant] = [:]

    public init() {}

    static func host(of request: URLRequest) -> String {
        request.url?.host(percentEncoded: false) ?? ""
    }

    public func cool(_ host: String, for wait: Duration) {
        let end = ContinuousClock.now + wait
        if let current = until[host], current >= end { return }
        until[host] = end
    }

    public func remaining(_ host: String) -> Duration {
        guard let end = until[host] else { return .zero }
        return max(.zero, end - .now)
    }

    func wait(for request: URLRequest) async {
        let left = remaining(Self.host(of: request))
        guard left > .zero else { return }
        try? await Task.sleep(for: left)
    }
}
