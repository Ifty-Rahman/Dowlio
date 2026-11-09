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
        let objects = page.embeddedObjects
        var known: [String: Story] = [:]
        for object in objects {
            Self.walk(object, story: Story()) { object, story in
                Self.remember(object, story: story, into: &known)
                return true
            }
        }
        for object in objects {
            Self.walk(object, story: Story()) { object, story in collect(object, story: &story, known: known, base: page.url, into: &found) }
        }
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

        static let labelWords = 6

        var label: String? {
            PostLabel.of(text: text, author: author, words: Self.labelWords, separator: " - ")
        }

        func filled(from earlier: Story?) -> Story {
            var story = self
            story.text = text ?? earlier?.text
            story.author = author ?? earlier?.author
            return story
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

    private static func walk(_ value: Any, story inherited: Story, visit: (_ object: [String: Any], _ story: inout Story) -> Bool) {
        if let list = value as? [Any] {
            for child in list { walk(child, story: inherited, visit: visit) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        var story = inherited
        if let text = postText(of: object) { story.text = text }
        if let author = author(of: object) { story.author = author }
        guard visit(object, &story) else { return }
        for child in object.values { walk(child, story: story, visit: visit) }
    }

    private static func remember(_ object: [String: Any], story: Story, into known: inout [String: Story]) {
        for media in object.objects("attachments").compactMap({ $0.object("media") }) {
            guard let id = media.text("id") else { continue }
            var own = story
            own.author = own.author ?? media.object("owner")?.text("name")
            known[id] = own.filled(from: known[id])
        }
    }

    private func collect(_ object: [String: Any], story: inout Story, known: [String: Story], base: URL, into found: inout [Item]) -> Bool {
        if object["attachments"] != nil || object["short_form_video_context"] != nil {
            let beside = object.filter { $0.key != "attachments" }
            story.text = story.text ?? Self.first(in: beside, depth: 8, Self.postText(of:))
            story.author = story.author ?? Self.first(in: beside, depth: 8, Self.author(of:))
        }
        guard isVideo(object) else { return true }
        var story = story
        story.author = story.author ?? object.object("owner")?.text("name")
        let id = object.text("id") ?? delivery(of: object)?.text("id")
        story = story.filled(from: id.flatMap { known[$0] })
        guard let video = video(in: object, label: story.label, base: base) else { return false }
        let item = Item(id: id, video: video)
        guard let id = item.id, let index = found.firstIndex(where: { $0.id == id }) else {
            found.append(item)
            return false
        }
        let label = found[index].video.label ?? video.label
        if item.isKept(over: found[index].video) { found[index] = item }
        found[index].video.label = label
        return false
    }

    private static func postText(of object: [String: Any]) -> String? {
        object.object("message")?.text("text") ?? object.object("savable_description")?.text("text")
    }

    private static func author(of object: [String: Any]) -> String? {
        object.objects("actors").first?.text("name") ?? object.object("video_owner")?.text("name")
    }

    private static func first(in value: Any, depth: Int, _ found: ([String: Any]) -> String?) -> String? {
        guard depth > 0 else { return nil }
        let children: [Any]
        if let list = value as? [Any] {
            children = list
        } else if let object = value as? [String: Any] {
            if let hit = found(object) { return hit }
            children = Array(object.values)
        } else {
            return nil
        }
        for child in children {
            if let hit = first(in: child, depth: depth - 1, found) { return hit }
        }
        return nil
    }

    private func isVideo(_ object: [String: Any]) -> Bool {
        guard object["__typename"] as? String ?? "Video" == "Video" else { return false }
        return delivery(of: object) != nil || legacy(of: object) != nil || Self.olderFileKeys.contains { object.text($0) != nil }
    }

    private func legacy(of object: [String: Any]) -> [String: Any]? {
        object.object("videoDeliveryLegacyFields")
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
        let older = legacy(of: media) ?? media
        let files = result.map { $0.objects("progressive_urls").compactMap { URL(json: $0["progressive_url"]) } }
            ?? Self.olderFileKeys.compactMap { URL(json: older[$0]) }
        let manifests = result.map { $0.objects("dash_manifests").compactMap { $0.text("manifest_xml") } } ?? [older.text("dash_manifest_xml_string")].compactMap { $0 }
        let dash = dashVersions(of: manifests, label: label, base: base)
        let streams = result?.objects("hls_playlist_urls").compactMap { URL(json: $0["hls_playlist_url"]) } ?? []
        let versions = Self.progressive(files) + dash.versions
        guard !versions.isEmpty || !streams.isEmpty else { return nil }
        return SiteVideo(label: label, thumbnail: thumbnail, duration: duration ?? dash.duration, versions: versions, streams: streams)
    }

    private func dashVersions(of manifests: [String], label: String?, base: URL) -> (versions: [Version], duration: Double?) {
        var versions: [Version] = []
        var duration: Double?
        for xml in manifests {
            guard let manifest = try? MPDParser.parse(Data(xml.utf8), base: base),
                  let dash = DASHVersions.candidate(of: manifest, label: label ?? "", thumbnail: nil), dash.restriction == nil else { continue }
            versions += dash.versions
            duration = duration ?? dash.duration
        }
        return (versions, duration)
    }

    private static func progressive(_ files: [URL]) -> [Version] {
        var seen = Set<URL>()
        return files.filter { seen.insert($0).inserted }.map { url in
            Version(source: .file(url), contentType: "video/mp4", height: MediaFile.height(inEncodingTagOf: url), codecs: MediaCodecs.h264WithAAC)
        }
    }

    private static func restriction(of media: [String: Any]) -> Candidate.Restriction? {
        if media["is_live_streaming"] as? Bool == true { return .live }
        guard let text = media.text("drm_info"), let info = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return ((info["video_license_uri_map"] as? [String: Any]) ?? [:]).isEmpty ? nil : .protected
    }
}
