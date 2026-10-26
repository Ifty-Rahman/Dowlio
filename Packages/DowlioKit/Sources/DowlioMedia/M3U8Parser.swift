import DowlioCore
import Foundation

public enum Playlist: Equatable, Sendable {
    case master(MasterPlaylist)
    case media(MediaPlaylist)
}

public struct MasterPlaylist: Equatable, Sendable {
    public var variants: [Variant]
    public var audio: [Rendition]
    public var isProtected = false
}

public struct Variant: Equatable, Sendable {
    public var url: URL
    public var bandwidth: Int?
    public var averageBandwidth: Int?
    public var height: Int?
    public var codecs: [String]
    public var audioGroup: String?
}

public struct Rendition: Equatable, Sendable {
    public var groupID: String
    public var name: String?
    public var url: URL?
    public var isDefault: Bool
}

public struct MediaPlaylist: Equatable, Sendable {
    public enum Encryption: Equatable, Sendable {
        case none
        case aes128
        case protected
    }

    public var fragments: [MediaFragment]
    public var initialization: MediaFragment?
    public var duration: Double
    public var isComplete: Bool
    public var encryption: Encryption

    public var singleFile: URL? {
        let pieces = (initialization.map { [$0] } ?? []) + fragments
        guard let first = pieces.first, pieces.allSatisfy({ $0.url == first.url && $0.bytes != nil }) else { return nil }
        var next: Int64 = 0
        for piece in pieces {
            guard let bytes = piece.bytes, bytes.lowerBound == next else { return nil }
            next = bytes.upperBound + 1
        }
        return first.url
    }
}

public enum M3U8Parser {
    public enum Error: Swift.Error, Equatable {
        case notAPlaylist
    }

    public static func parse(_ text: String, base: URL) throws -> Playlist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw Error.notAPlaylist }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) { return .master(master(lines, base: base)) }
        return .media(media(lines, base: base))
    }

    private static func master(_ lines: [String], base: URL) -> MasterPlaylist {
        var variants: [Variant] = []
        var audio: [Rendition] = []
        var isProtected = false
        var pending: [String: String]?
        for line in lines {
            if let value = line.value(of: "#EXT-X-SESSION-KEY:") {
                if case .protected = KeyTag(attributes(value)) { isProtected = true }
            } else if let value = line.value(of: "#EXT-X-STREAM-INF:") {
                pending = attributes(value)
            } else if let value = line.value(of: "#EXT-X-MEDIA:") {
                let found = attributes(value)
                guard found["TYPE"] == "AUDIO", let group = found["GROUP-ID"] else { continue }
                audio.append(Rendition(
                    groupID: group, name: found["NAME"], url: found["URI"].flatMap { resolve($0, base) }, isDefault: found["DEFAULT"] == "YES"
                ))
            } else if !line.hasPrefix("#"), let found = pending, let url = resolve(line, base) {
                pending = nil
                let size = found["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(
                    url: url,
                    bandwidth: found["BANDWIDTH"].flatMap { Int($0) },
                    averageBandwidth: found["AVERAGE-BANDWIDTH"].flatMap { Int($0) },
                    height: size.flatMap { $0.count == 2 ? $0.min() : nil },
                    codecs: found["CODECS"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? [],
                    audioGroup: found["AUDIO"]
                ))
            }
        }
        return MasterPlaylist(variants: variants, audio: audio, isProtected: isProtected)
    }

    private static func media(_ lines: [String], base: URL) -> MediaPlaylist {
        var fragments: [MediaFragment] = []
        var initialization: MediaFragment?
        var duration = 0.0
        var isComplete = false
        var encryption = MediaPlaylist.Encryption.none
        var pendingRange: (length: Int64, offset: Int64?)?
        var nextOffset: [URL: Int64] = [:]
        var sequence: UInt64 = 0
        var key: PendingKey?
        for line in lines {
            if let value = line.value(of: "#EXT-X-MEDIA-SEQUENCE:") {
                sequence = UInt64(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if let value = line.value(of: "#EXTINF:") {
                duration += Double(value.split(separator: ",").first ?? "") ?? 0
            } else if let value = line.value(of: "#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(value)
            } else if let value = line.value(of: "#EXT-X-MAP:") {
                let found = attributes(value)
                guard let url = found["URI"].flatMap({ resolve($0, base) }) else { continue }
                let range = found["BYTERANGE"].flatMap(byteRange)
                initialization = MediaFragment(
                    url: url, bytes: range.map { closed($0.length, at: $0.offset ?? 0) }, key: key?.fragmentKey(sequence: sequence)
                )
                if let range { nextOffset[url] = (range.offset ?? 0) + range.length }
            } else if let value = line.value(of: "#EXT-X-KEY:") {
                let found = attributes(value)
                switch KeyTag(found) {
                case .none:
                    key = nil
                case .aes128:
                    guard let url = found["URI"].flatMap({ resolve($0, base) }) else {
                        encryption = .protected
                        key = nil
                        continue
                    }
                    if encryption == .none { encryption = .aes128 }
                    key = PendingKey(url: url, iv: found["IV"].flatMap(iv))
                case .protected:
                    encryption = .protected
                    key = nil
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isComplete = true
            } else if !line.hasPrefix("#"), let url = resolve(line, base) {
                var bytes: ClosedRange<Int64>?
                if let range = pendingRange {
                    let offset = range.offset ?? nextOffset[url] ?? 0
                    bytes = closed(range.length, at: offset)
                    nextOffset[url] = offset + range.length
                }
                pendingRange = nil
                fragments.append(MediaFragment(url: url, bytes: bytes, key: key?.fragmentKey(sequence: sequence + UInt64(fragments.count))))
            }
        }
        return MediaPlaylist(
            fragments: fragments, initialization: initialization, duration: duration, isComplete: isComplete, encryption: encryption
        )
    }

    private struct PendingKey {
        var url: URL
        var iv: Data?

        func fragmentKey(sequence: UInt64) -> FragmentKey {
            FragmentKey(url: url, iv: iv ?? Data(repeating: 0, count: 8) + withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
        }
    }

    private enum KeyTag {
        case none
        case aes128
        case protected

        init(_ attributes: [String: String]) {
            let method = attributes["METHOD"] ?? "NONE"
            let format = attributes["KEYFORMAT"] ?? "identity"
            if method == "NONE" {
                self = .none
            } else if method == "AES-128" && format == "identity" {
                self = .aes128
            } else {
                self = .protected
            }
        }
    }

    private static func iv(_ text: String) -> Data? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        hex = String(repeating: "0", count: 32 - hex.count) + hex
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private static func byteRange(_ value: String) -> (length: Int64, offset: Int64?)? {
        let parts = value.split(separator: "@")
        guard let length = parts.first.flatMap({ Int64($0) }), length > 0 else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    private static func closed(_ length: Int64, at offset: Int64) -> ClosedRange<Int64> {
        offset...(offset + length - 1)
    }

    private static func resolve(_ value: String, _ base: URL) -> URL? {
        URL(string: value, relativeTo: base)?.absoluteURL
    }

    static func attributes(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func commit() {
            if !key.isEmpty { found[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for character in text {
            if readingKey {
                if character == "=" { readingKey = false } else if character == "," { commit() } else { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return found
    }
}

private extension String {
    func value(of tag: String) -> String? {
        hasPrefix(tag) ? String(dropFirst(tag.count)) : nil
    }
}
