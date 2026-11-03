import Foundation

public struct PinterestReader: SiteReader {
    public let name = "Pinterest"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["pinterest.com", "pin.it"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) || PageAnalyzer.site(of: page).hasPrefix("pinterest.")
    }

    public func post(in page: URL) -> String? {
        if page.isOn(["pin.it"]) { return page.pathComponents.dropFirst().first }
        guard let part = page.pathComponent(after: ["pin"]) else { return nil }
        let id = part.components(separatedBy: "--").last ?? part
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var pins: [String: [String: Any]] = [:]
        var order: [String] = []
        for pin in page.embeddedObjects.flatMap(Self.pins(in:)) {
            guard let id = pin.text("id") else { continue }
            if pins[id] == nil { order.append(id) }
            if Self.files(of: pin).count > Self.files(of: pins[id] ?? [:]).count { pins[id] = pin }
        }
        let chosen: [String]
        if page.url.isOn(["pin.it"]) {
            let main = page.embeddedObjects.lazy.compactMap { ($0 as? [String: Any])?.object("resources")?.object("PinResource") }
                .flatMap { Self.pins(in: $0) }.compactMap { $0.text("id") }.first
            chosen = main.map { [$0] } ?? Array(order.prefix(1))
        } else if let id = post(in: page.url) {
            chosen = order.filter { $0 == id }
        } else {
            chosen = order
        }
        return chosen.compactMap { pins[$0].flatMap(Self.video(of:)) }
    }

    private static func pins(in value: Any) -> [[String: Any]] {
        if let list = value as? [Any] { return list.flatMap(pins(in:)) }
        guard let object = value as? [String: Any] else { return [] }
        if object.text("id") != nil, !files(of: object).isEmpty { return [object] }
        return object.values.flatMap(pins(in:))
    }

    private static func files(of pin: [String: Any]) -> [[String: Any]] {
        let own = pin.object("videos")?.object("video_list").map { Array($0.values) } ?? []
        let pages = pin.object("story_pin_data")?.objects("pages") ?? []
        let story = pages.flatMap { $0.objects("blocks") }.compactMap { $0.object("video")?.object("video_list") }.flatMap(\.values)
        return (own + story).compactMap { $0 as? [String: Any] }
    }

    private static func video(of pin: [String: Any]) -> SiteVideo? {
        var seen = Set<URL>()
        let files = Self.files(of: pin).compactMap { file in URL(json: file["url"]).map { (url: $0, file: file) } }.filter { seen.insert($0.url).inserted }
        let versions = files.filter { $0.url.pathExtension.lowercased() == "mp4" }.map { found in
            Version(source: .file(found.url), contentType: "video/mp4", height: shorterSide(found.file["width"], found.file["height"]), codecs: MediaCodecs.h264WithAAC)
        }
        let streams = versions.isEmpty ? files.map(\.url).filter { HLSVersions.isPlaylist($0) } : []
        guard !versions.isEmpty || !streams.isEmpty else { return nil }
        let creator = pin.object("native_creator") ?? pin.object("pinner")
        let text = pin.text("title") ?? pin.text("grid_title") ?? pin.text("description")
        return SiteVideo(
            label: PostLabel.of(text: text, author: text == nil ? nil : creator?.text("full_name") ?? creator?.text("username")),
            thumbnail: files.lazy.compactMap { URL(json: $0.file["thumbnail"]) }.first,
            duration: files.lazy.compactMap { jsonNumber($0.file["duration"]) }.first.map { $0 / 1000 },
            versions: versions, streams: streams
        )
    }
}
