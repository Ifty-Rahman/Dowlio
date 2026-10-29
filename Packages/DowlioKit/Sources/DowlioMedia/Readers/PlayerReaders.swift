import Foundation

public struct WebPlayerReader: SiteReader {
    public let name: String
    private let setupCalls: [NSRegularExpression]
    private let setupAttributes: [String]
    private let readsVideoJSElements: Bool

    init(name: String, setupCalls: [String], setupAttributes: [String] = [], readsVideoJSElements: Bool = false) {
        self.name = name
        self.setupCalls = setupCalls.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        self.setupAttributes = setupAttributes
        self.readsVideoJSElements = readsVideoJSElements
    }

    static let jwPlayerSetup = #"jwplayer\s*\([^)]*\)\s*\.setup\s*\(\s*"#

    public static let videoJS = WebPlayerReader(
        name: "Video.js", setupCalls: [#"videojs\s*\([^,()]*,\s*"#], setupAttributes: ["data-setup"], readsVideoJSElements: true
    )
    public static let plyr = WebPlayerReader(
        name: "Plyr", setupCalls: [#"new\s+Plyr\s*\([^,()]*,\s*"#, #"\bplayer\.source\s*=\s*"#], setupAttributes: ["data-plyr-config"]
    )
    public static let flowplayer = WebPlayerReader(
        name: "Flowplayer", setupCalls: [#"flowplayer\s*\([^,()]*,\s*"#, #"flowplayer\s*\(\s*(?=\{)"#], setupAttributes: ["data-flowplayer"]
    )
    public static let clappr = WebPlayerReader(name: "Clappr", setupCalls: [#"new\s+Clappr\.Player\s*\(\s*"#])

    public static let all: [any SiteReader] = [JWPlayerReader(), videoJS, plyr, flowplayer, clappr]

    public func recognises(_ page: URL) -> Bool { false }

    public func recognisesPlayer(in html: String) -> Bool {
        let whole = NSRange(location: 0, length: (html as NSString).length)
        if setupCalls.contains(where: { $0.firstMatch(in: html, range: whole) != nil }) { return true }
        if readsVideoJSElements, html.range(of: "<video-js", options: .caseInsensitive) != nil { return true }
        return setupAttributes.contains { html.range(of: $0 + "=", options: .caseInsensitive) != nil }
    }

    public func post(in page: URL) -> String? { nil }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let html = page.html else { return [] }
        var setups = PlayerSetup.objects(in: html, after: setupCalls)
        for attribute in setupAttributes { setups += PlayerSetup.attributeValues(attribute, in: html) }
        var videos = setups.compactMap { PlayerSetup($0).video(base: page.url) }
        if readsVideoJSElements { videos += PlayerSetup.videoJSTags(in: html, base: page.url) }
        return videos
    }
}
