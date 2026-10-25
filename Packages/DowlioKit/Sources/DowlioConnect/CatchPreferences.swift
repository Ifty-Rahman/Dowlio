import Foundation

public struct CatchPreferences: Equatable, Sendable {
    public static let maximumSites = 500

    public var catches: Bool
    public var sharesSignIn: Bool
    public private(set) var neverCatch: [String] = []
    public private(set) var noSignIn: [String] = []

    public init(catches: Bool = true, neverCatch: [String] = [], sharesSignIn: Bool = true, noSignIn: [String] = []) {
        self.catches = catches
        self.sharesSignIn = sharesSignIn
        for site in neverCatch { neverCatchOn(site) }
        for site in noSignIn { noSignInOn(site) }
    }

    public mutating func neverCatchOn(_ site: String) {
        Self.add(site, to: &neverCatch)
    }

    public mutating func catchAgain(_ site: String) {
        neverCatch.removeAll { $0 == site }
    }

    public mutating func noSignInOn(_ site: String) {
        Self.add(site, to: &noSignIn)
    }

    public mutating func signInAgain(_ site: String) {
        noSignIn.removeAll { $0 == site }
    }

    public func allowsSignIn(for host: String) -> Bool {
        guard sharesSignIn, let host = Self.site(host) else { return false }
        return !noSignIn.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func add(_ site: String, to list: inout [String]) {
        guard list.count < maximumSites, let site = Self.site(site), !list.contains(site) else { return }
        list.append(site)
        list.sort()
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

public struct SignInSite: Codable, Equatable, Identifiable, Sendable {
    public let host: String
    public var uses: Int
    public var lastUsed: Date

    public var id: String { host }
}

public struct SignInLog: Codable, Equatable, Sendable {
    public static let maximumSites = 300

    public private(set) var sites: [SignInSite] = []

    public init() {}

    public mutating func record(_ host: String, at date: Date) {
        if let index = sites.firstIndex(where: { $0.host == host }) {
            sites[index].uses += 1
            sites[index].lastUsed = date
        } else {
            sites.append(SignInSite(host: host, uses: 1, lastUsed: date))
        }
        sites.sort { $0.lastUsed > $1.lastUsed }
        if sites.count > Self.maximumSites { sites.removeLast(sites.count - Self.maximumSites) }
    }

    public mutating func remove(_ host: String) {
        sites.removeAll { $0.host == host }
    }
}
