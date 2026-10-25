import Foundation

public struct CatchPreferences: Equatable, Sendable {
    public static let maximumSites = 500

    public var catches: Bool
    public private(set) var neverCatch: [String] = []

    public init(catches: Bool = true, neverCatch: [String] = []) {
        self.catches = catches
        for site in neverCatch { neverCatchOn(site) }
    }

    public mutating func neverCatchOn(_ site: String) {
        guard neverCatch.count < Self.maximumSites, let site = Self.site(site), !neverCatch.contains(site) else { return }
        neverCatch.append(site)
        neverCatch.sort()
    }

    public mutating func catchAgain(_ site: String) {
        neverCatch.removeAll { $0 == site }
    }

    static func site(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return host
    }
}

public struct CatchPreferenceChange: Equatable, Sendable {
    public var catches: Bool?
    public var neverCatchSite: String?

    public init(catches: Bool? = nil, neverCatchSite: String? = nil) {
        self.catches = catches
        self.neverCatchSite = neverCatchSite
    }

    public func applied(to preferences: CatchPreferences) -> CatchPreferences {
        var result = preferences
        if let catches { result.catches = catches }
        if let neverCatchSite { result.neverCatchOn(neverCatchSite) }
        return result
    }
}
