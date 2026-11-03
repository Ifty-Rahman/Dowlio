import Foundation

public struct SnapchatReader: SiteReader {
    public let name = "Snapchat Spotlight"
    private let hosts: Set<String>
    private static let untitled = "Spotlight Snap"

    public init(hosts: Set<String> = ["snapchat.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && page.pathComponents.contains("spotlight")
    }

    public func post(in page: URL) -> String? {
        page.pathComponent(after: ["spotlight"])
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var seen = Set<Set<String>>()
        let stories = page.embeddedObjects.flatMap(Self.stories(in:)).filter { seen.insert($0.snapIDs).inserted }
        let id = post(in: page.url)
        return stories.filter { id.map($0.snapIDs.contains) ?? true }.compactMap(\.video)
    }

    private struct Story {
        var snapIDs: Set<String>
        var video: SiteVideo?
    }

    private static func stories(in value: Any) -> [Story] {
        if let list = value as? [Any] { return list.flatMap(stories(in:)) }
        guard let object = value as? [String: Any] else { return [] }
        if let metadata = object.object("metadata")?.object("videoMetadata"),
           let snaps = object.object("story")?.objects("snapList"), !snaps.isEmpty {
            return [Story(snapIDs: Set(snaps.compactMap { $0.object("snapId")?.text("value") }), video: video(of: metadata))]
        }
        return object.values.flatMap(stories(in:))
    }

    private static func video(of metadata: [String: Any]) -> SiteVideo? {
        guard let url = URL(json: metadata["contentUrl"]) else { return nil }
        let title = metadata.text("embeddedTextCaption") ?? metadata.text("name").flatMap { $0 == untitled ? nil : $0 }
        let creator = metadata.object("creator")?.object("personCreator")
        let author = creator?.text("name") ?? creator?.text("username")
        return SiteVideo(
            label: PostLabel.of(text: title, author: title == nil ? nil : author),
            thumbnail: URL(json: metadata["thumbnailUrl"]),
            duration: jsonNumber(metadata["durationMs"]).map { $0 / 1000 },
            versions: [Version(source: .file(url), contentType: "video/mp4", height: shorterSide(metadata["width"], metadata["height"]), codecs: MediaCodecs.h264WithAAC)]
        )
    }
}
