import DowlioCore
import Foundation

public struct DASHManifest: Equatable, Sendable {
    public var isDynamic: Bool
    public var isProtected: Bool
    public var duration: Double?
    public var tracks: [DASHTrack]
}

public struct DASHTrack: Equatable, Sendable {
    public enum Kind: Sendable {
        case video
        case audio
        case other
    }

    public var id: String
    public var kind: Kind
    public var mimeType: String?
    public var bandwidth: Int?
    public var height: Int?
    public var codecs: [String]
    public var language: String?
    public var isMain: Bool
    public var initialization: MediaFragment?
    public var fragments: [MediaFragment]
}

public enum MPDParser {
    public enum Error: Swift.Error, Equatable {
        case notAManifest
    }

    public static func parse(_ data: Data, base: URL) throws -> DASHManifest {
        guard let root = XMLTree.parse(data), root.name == "MPD" else { throw Error.notAManifest }
        let rootBase = root.baseURL(against: base)
        let total = root["mediaPresentationDuration"].flatMap(HTMLReader.isoDuration)
        var isProtected = !root.children("ContentProtection").isEmpty
        var tracks: [DASHTrack] = []
        let periods = root.children("Period")
        for period in periods {
            let periodBase = period.baseURL(against: rootBase)
            if !period.children("ContentProtection").isEmpty { isProtected = true }
            let length = period["duration"].flatMap(HTMLReader.isoDuration) ?? (periods.count == 1 ? total : nil)
            for set in period.children("AdaptationSet") {
                let setBase = set.baseURL(against: periodBase)
                if !set.children("ContentProtection").isEmpty { isProtected = true }
                for element in set.children("Representation") {
                    if !element.children("ContentProtection").isEmpty { isProtected = true }
                    let id = element["id"] ?? ""
                    let address = element.baseURL(against: setBase)
                    let scope = [element, set, period]
                    let layout = FragmentLayout(scope: scope, address: address, id: id, bandwidth: element["bandwidth"], length: length)
                    let mimeType = element["mimeType"] ?? set["mimeType"]
                    let found = DASHTrack(
                        id: id,
                        kind: kind(contentType: element["contentType"] ?? set["contentType"], mimeType: mimeType),
                        mimeType: mimeType,
                        bandwidth: element["bandwidth"].flatMap { Int($0) },
                        height: element["FBQualityLabel"].flatMap(MediaFile.height(in:)) ?? (element["height"] ?? set["height"]).flatMap { Int($0) },
                        codecs: (element["codecs"] ?? set["codecs"]).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? [],
                        language: element["lang"] ?? set["lang"],
                        isMain: set.children("Role").contains { $0["value"] == "main" },
                        initialization: layout.initialization,
                        fragments: layout.fragments
                    )
                    if let index = tracks.firstIndex(where: { $0.id == id && $0.kind == found.kind && $0.initialization == found.initialization }) {
                        tracks[index].fragments += found.fragments
                    } else if !tracks.contains(where: { $0.id == id && $0.kind == found.kind }) {
                        tracks.append(found)
                    }
                }
            }
        }
        return DASHManifest(isDynamic: root["type"] == "dynamic", isProtected: isProtected, duration: total, tracks: tracks)
    }

    private static func kind(contentType: String?, mimeType: String?) -> DASHTrack.Kind {
        let type = contentType ?? mimeType?.split(separator: "/").first.map(String.init) ?? ""
        switch type.lowercased() {
        case "video": return .video
        case "audio": return .audio
        default: return .other
        }
    }

    private struct FragmentLayout {
        var initialization: MediaFragment?
        var fragments: [MediaFragment] = []

        init(scope: [XMLTree], address: URL, id: String, bandwidth: String?, length: Double?) {
            if let list = scope.lazy.compactMap({ $0.children("SegmentList").first }).first {
                initialization = list.children("Initialization").first.map { Self.fragment($0, url: "sourceURL", range: "range", address: address) }
                fragments = list.children("SegmentURL").map { Self.fragment($0, url: "media", range: "mediaRange", address: address) }
            } else if scope.contains(where: { !$0.children("SegmentTemplate").isEmpty }) {
                readTemplate(scope.compactMap { $0.children("SegmentTemplate").first }, address: address, id: id, bandwidth: bandwidth, length: length)
            } else {
                fragments = [MediaFragment(url: address)]
            }
        }

        private static func fragment(_ element: XMLTree, url key: String, range: String, address: URL) -> MediaFragment {
            let url = element[key].flatMap { URL(string: $0, relativeTo: address)?.absoluteURL } ?? address
            let bytes = element[range].flatMap(Self.range)
            return MediaFragment(url: url, bytes: bytes)
        }

        private static func range(_ text: String) -> ClosedRange<Int64>? {
            let parts = text.split(separator: "-").compactMap { Int64($0) }
            guard parts.count == 2, parts[0] <= parts[1] else { return nil }
            return parts[0]...parts[1]
        }

        private mutating func readTemplate(_ templates: [XMLTree], address base: URL, id: String, bandwidth: String?, length: Double?) {
            func attribute(_ name: String) -> String? { templates.lazy.compactMap { $0[name] }.first }
            let timescale = attribute("timescale").flatMap { Double($0) } ?? 1
            let startNumber = attribute("startNumber").flatMap { Int($0) } ?? 1
            func address(_ template: String, number: Int?, time: Int?) -> URL? {
                URL(string: Self.fill(template, id: id, bandwidth: bandwidth, number: number, time: time), relativeTo: base)?.absoluteURL
            }
            initialization = attribute("initialization").flatMap { address($0, number: nil, time: nil) }.map { MediaFragment(url: $0) }
            guard let media = attribute("media") else { return }
            if let timeline = templates.lazy.compactMap({ $0.children("SegmentTimeline").first }).first {
                var time = 0
                var number = startNumber
                let end = length.map { Int($0 * timescale) }
                for entry in timeline.children("S") {
                    guard let duration = entry["d"].flatMap({ Int($0) }), duration > 0 else { continue }
                    if let start = entry["t"].flatMap({ Int($0) }) { time = start }
                    let declared = entry["r"].flatMap { Int($0) } ?? 0
                    let repeats = declared >= 0 ? declared : end.map { max(($0 - time + duration - 1) / duration - 1, 0) } ?? 0
                    for _ in 0...repeats {
                        if let found = address(media, number: number, time: time) { fragments.append(MediaFragment(url: found)) }
                        time += duration
                        number += 1
                    }
                }
            } else if let duration = attribute("duration").flatMap({ Double($0) }), duration > 0, let length {
                let count = Int((length * timescale / duration).rounded(.up))
                fragments = (0..<count).compactMap { offset in
                    address(media, number: startNumber + offset, time: Int(Double(offset) * duration)).map { MediaFragment(url: $0) }
                }
            }
        }

        private static let templateToken = try! NSRegularExpression(pattern: #"\$(RepresentationID|Number|Bandwidth|Time)(%0(\d+)d)?\$|\$\$"#)

        private static func fill(_ template: String, id: String, bandwidth: String?, number: Int?, time: Int?) -> String {
            let text = template as NSString
            var result = ""
            var last = 0
            for match in templateToken.matches(in: template, range: NSRange(location: 0, length: text.length)) {
                result += text.substring(with: NSRange(location: last, length: match.range.location - last))
                last = match.range.location + match.range.length
                guard match.range(at: 1).location != NSNotFound else {
                    result += "$"
                    continue
                }
                let width = match.range(at: 3).location == NSNotFound ? 0 : Int(text.substring(with: match.range(at: 3))) ?? 0
                let value: String? = switch text.substring(with: match.range(at: 1)) {
                case "RepresentationID": id
                case "Number": number.map(String.init)
                case "Bandwidth": bandwidth
                default: time.map(String.init)
                }
                let filled = value ?? ""
                result += String(repeating: "0", count: max(width - filled.count, 0)) + filled
            }
            return result + text.substring(from: last)
        }
    }
}
