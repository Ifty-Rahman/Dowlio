import Foundation

public struct FacebookReader: SiteReader {
    public let name = "Facebook"
    private let hosts: Set<String>

    private static let videoPaths: Set<String> = ["reel", "videos"]
    private static let postPaths: Set<String> = ["posts", "permalink", "v", "r"]
    private static let postPages: Set<String> = ["permalink.php", "story.php"]
    private static let olderFileKeys = ["browser_native_sd_url", "playable_url", "browser_native_hd_url", "playable_url_quality_hd"]

    public init(hosts: Set<String> = ["facebook.com", "fb.watch"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        permalink(in: page).map { link in
            switch link {
            case .video(let id), .post(let id): id
            }
        }
    }

    private enum Permalink {
        case video(String)
        case post(String)
    }

    private func permalink(in page: URL) -> Permalink? {
        let parts = Array(page.pathComponents.dropFirst())
        let query = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryID(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if page.isOn(["fb.watch"]), let code = parts.first { return .post(code) }
        if let index = parts.firstIndex(where: Self.videoPaths.contains),
           let id = parts[(index + 1)...].first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return .video(id)
        }
        if parts.contains(where: { ["watch", "video.php"].contains($0) }), let id = queryID("v") { return .video(id) }
        if parts.contains(where: Self.postPages.contains), let id = queryID("story_fbid") { return .post(id) }
        if let index = parts.lastIndex(where: Self.postPaths.contains), index + 1 < parts.count { return .post(parts[index + 1]) }
        return nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var found: [Item] = []
        for object in page.embeddedObjects { collect(object, story: Story(), base: page.url, into: &found) }
        switch permalink(in: page.url) {
        case nil: return found.map(\.video)
        case .video(let id): return found.filter { $0.id == id }.map(\.video)
        case .post(let id):
            let own = found.filter { $0.id == id }
            return (own.isEmpty ? Array(found.prefix(1)) : own).map(\.video)
        }
    }

    private struct Story {
        var text: String?
        var author: String?

        var label: String? {
            text == nil ? nil : PostLabel.of(text: text, author: author)
        }
    }

    private struct Item {
        var id: String?
        var video: SiteVideo

        func isKept(over other: SiteVideo) -> Bool {
            if video.restriction != nil { return other.restriction == nil }
            return other.restriction == nil && video.versions.count > other.versions.count
        }
    }

    private func collect(_ value: Any, story inherited: Story, base: URL, into found: inout [Item]) {
        if let list = value as? [Any] {
            for child in list { collect(child, story: inherited, base: base, into: &found) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        var story = inherited
        if let text = object.object("message")?.text("text") { story.text = text }
        if let author = object.objects("actors").first?.text("name") ?? object.object("video_owner")?.text("name") { story.author = author }
        guard isVideo(object) else {
            for child in object.values { collect(child, story: story, base: base, into: &found) }
            return
        }
        story.author = story.author ?? object.object("owner")?.text("name")
        guard let video = video(in: object, label: story.label, base: base) else { return }
        let item = Item(id: object.text("id") ?? delivery(of: object)?.text("id"), video: video)
        guard let id = item.id, let index = found.firstIndex(where: { $0.id == id }) else { return found.append(item) }
        let label = found[index].video.label ?? video.label
        if item.isKept(over: found[index].video) { found[index] = item }
        found[index].video.label = label
    }

    private func isVideo(_ object: [String: Any]) -> Bool {
        guard object["__typename"] as? String ?? "Video" == "Video" else { return false }
        return delivery(of: object) != nil || Self.olderFileKeys.contains { object.text($0) != nil }
    }

    private func delivery(of object: [String: Any]) -> [String: Any]? {
        object.object("videoDeliveryResponseFragment")?.object("videoDeliveryResponseResult")
    }

    private func video(in media: [String: Any], label: String?, base: URL) -> SiteVideo? {
        let thumbnail = URL(json: media.object("preferred_thumbnail")?.object("image")?["uri"]) ?? URL(json: media.object("first_frame_thumbnail")?["uri"])
        let duration = jsonNumber(media["length_in_second"]) ?? jsonNumber(media["playable_duration_in_ms"]).map { $0 / 1000 }
        if let restriction = Self.restriction(of: media) {
            return SiteVideo(label: label, thumbnail: thumbnail, duration: duration, restriction: restriction)
        }
        let result = delivery(of: media)
        let files = result.map { $0.objects("progressive_urls").compactMap { URL(json: $0["progressive_url"]) } }
            ?? Self.olderFileKeys.compactMap { URL(json: media[$0]) }
        let dash = result.map { dashVersions(in: $0, label: label, base: base) }
        let streams = result?.objects("hls_playlist_urls").compactMap { URL(json: $0["hls_playlist_url"]) } ?? []
        let versions = Self.progressive(files) + (dash?.versions ?? [])
        guard !versions.isEmpty || !streams.isEmpty else { return nil }
        return SiteVideo(label: label, thumbnail: thumbnail, duration: duration ?? dash?.duration, versions: versions, streams: streams)
    }

    private func dashVersions(in result: [String: Any], label: String?, base: URL) -> (versions: [Version], duration: Double?) {
        var versions: [Version] = []
        var duration: Double?
        for entry in result.objects("dash_manifests") {
            guard let xml = entry.text("manifest_xml"), let manifest = try? MPDParser.parse(Data(xml.utf8), base: base),
                  let dash = DASHVersions.candidate(of: manifest, label: label ?? "", thumbnail: nil), dash.restriction == nil else { continue }
            versions += dash.versions
            duration = duration ?? dash.duration
        }
        return (versions, duration)
    }

    private static func progressive(_ files: [URL]) -> [Version] {
        var seen = Set<URL>()
        return files.filter { seen.insert($0).inserted }.map { url in
            Version(source: .file(url), contentType: "video/mp4", height: height(of: url), codecs: "H.264 + AAC")
        }
    }

    private static func restriction(of media: [String: Any]) -> Candidate.Restriction? {
        if media["is_live_streaming"] as? Bool == true { return .live }
        guard let text = media.text("drm_info"), let info = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return ((info["video_license_uri_map"] as? [String: Any]) ?? [:]).isEmpty ? nil : .protected
    }

    static func height(of url: URL) -> Int? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard var encoded = query.first(where: { $0.name == "efg" })?.value else { return nil }
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["vencode_tag"] as? String,
              let match = tag.firstMatch(of: /\.(\d{3,4})\./) else { return nil }
        return Int(match.1)
    }
}
