import Foundation

public struct PlayedPage: Equatable, Sendable {
    public var title: String?
    public var media: [WatchedRequest]

    public init(title: String? = nil, media: [WatchedRequest] = []) {
        self.title = title
        self.media = media
    }
}

public typealias LookAgain = @Sendable (SentPage) async -> PlayedPage

extension SentPage {
    func played(_ played: PlayedPage) -> SentPage {
        var seen = self
        seen.title = played.title ?? title
        seen.scan = []
        seen.embeddedJSON = []
        seen.watched = played.media
        return seen
    }
}

extension AsyncStream where Element == PageAnalysis {
    public static var nothingFound: AsyncStream<PageAnalysis> {
        AsyncStream { $0.yield(.found([])); $0.finish() }
    }
}
