import Foundation

public struct ThreadsReader: SiteReader {
    public let name = "Threads"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["threads.com", "threads.net"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        page.pathComponent(after: ["post", "t"])
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        MetaMedia.videos(on: page, post: post(in: page.url))
    }
}
