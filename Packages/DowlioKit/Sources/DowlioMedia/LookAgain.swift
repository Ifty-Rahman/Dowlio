import Foundation

public struct PlayedPage: Equatable, Sendable {
    public var title: String?
    public var media: [WatchedRequest]
    public var userAgent: String?
    public var players: [ScannedPlayer]
    public var scan: [ScannedMedia]
    public var embeddedJSON: [String]
    public var html: String?

    public init(
        title: String? = nil, media: [WatchedRequest] = [], userAgent: String? = nil, players: [ScannedPlayer] = [], scan: [ScannedMedia] = [],
        embeddedJSON: [String] = [], html: String? = nil
    ) {
        self.title = title
        self.media = media
        self.userAgent = userAgent
        self.players = players
        self.scan = scan
        self.embeddedJSON = embeddedJSON
        self.html = html.map { String(decoding: Data($0.utf8.prefix(PageAnalyzer.largestPage)), as: UTF8.self) }
    }
}

public typealias LookAgain = @Sendable (SentPage) async -> PlayedPage

extension SentPage {
    func played(_ played: PlayedPage) -> SentPage {
        var seen = self
        seen.title = played.title ?? title
        let rendered = !played.scan.isEmpty || !played.players.isEmpty || !played.embeddedJSON.isEmpty
        seen.scan = rendered ? played.scan : scan
        seen.players = rendered ? played.players : players
        seen.embeddedJSON = rendered ? played.embeddedJSON : embeddedJSON
        seen.watched = played.media
        seen.userAgent = userAgent ?? played.userAgent
        return seen
    }
}

extension AsyncStream where Element == PageAnalysis {
    public static var nothingFound: AsyncStream<PageAnalysis> {
        found([])
    }

    public static func found(_ candidates: [Candidate]) -> AsyncStream<PageAnalysis> {
        AsyncStream { $0.yield(.found(candidates)); $0.finish() }
    }
}
