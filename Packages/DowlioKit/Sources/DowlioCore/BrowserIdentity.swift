import Foundation

public struct BrowserIdentity: Equatable, Sendable {
    public var userAgent: String?
    public var acceptLanguage: String?

    public init(userAgent: String?, languages: [String] = Locale.preferredLanguages) {
        self.userAgent = userAgent
        acceptLanguage = Self.acceptLanguage(languages)
    }

    private static func acceptLanguage(_ languages: [String]) -> String? {
        let listed = languages.prefix(9).enumerated().map { index, language in
            index == 0 ? language : "\(language);q=0.\(10 - index)"
        }
        return listed.isEmpty ? nil : listed.joined(separator: ",")
    }
}
