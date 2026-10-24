import Foundation
import UniformTypeIdentifiers

enum FileNaming {
    /// The finished file's name: from `Content-Disposition`, otherwise from the final URL after
    /// redirects, otherwise "download". A name without an extension gets one
    /// from the content type.
    static func name(for response: HTTPURLResponse, finalURL: URL) -> String {
        var name = name(for: finalURL)
        if let header = response.value(forHTTPHeaderField: "Content-Disposition"),
           let suggested = ContentDisposition.fileName(in: header) {
            name = suggested
        }
        name = clean(name)
        if split(name).ext.isEmpty, let ext = fileExtension(for: response) {
            name += ".\(ext)"
        }
        return capped(name)
    }

    static let maximumBytes = 200

    /// A name the user typed, made safe the same way as a server's.
    static func chosen(_ name: String) -> String {
        capped(clean(name))
    }

    /// Cuts `name` to at most 200 UTF-8 bytes on a character boundary. The extension is kept when
    /// it's short enough to leave room for a name.
    static func capped(_ name: String) -> String {
        guard name.utf8.count > maximumBytes else { return name }
        let (nameBase, ext) = split(name)
        let suffix = ext.isEmpty || ext.utf8.count > 20 ? "" : ".\(ext)"
        var base = Substring(suffix.isEmpty ? name : nameBase)
        while base.utf8.count + suffix.utf8.count > maximumBytes {
            base = base.dropLast()
        }
        return String(base) + suffix
    }

    static func split(_ name: String) -> (base: String, ext: String) {
        ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
    }

    /// Removes `/`, `:` and control characters, then leading dots, so a name from a server can't
    /// leave the folder or make a hidden file. Returns "download" if nothing is left.
    static func clean(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(kept)).drop { $0 == "." }
        return cleaned.isEmpty ? "download" : String(cleaned)
    }

    /// The preferred extension for the response's `Content-Type`, if it has one.
    private static func fileExtension(for response: HTTPURLResponse) -> String? {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let mimeType = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return UTType(mimeType: mimeType)?.preferredFilenameExtension
    }

    /// The name a link suggests on its own. The engine shows it until the probe answers.
    static func name(for url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? "download" : last
    }
}

/// Reads the file name from a `Content-Disposition` header (RFC 6266).
enum ContentDisposition {
    /// `filename*` (RFC 8187) when it decodes, otherwise `filename`.
    static func fileName(in header: String) -> String? {
        let parameters = parameters(in: header)
        if let encoded = parameters.first(where: { $0.name == "filename*" })?.value,
           let decoded = decodeExtendedValue(encoded) {
            return decoded
        }
        return parameters.first { $0.name == "filename" }?.value
    }

    /// Decodes `charset'language'percent-encoded-bytes`. UTF-8 and ISO-8859-1 only.
    private static func decodeExtendedValue(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let encoding: String.Encoding
        switch parts[0].lowercased() {
        case "utf-8": encoding = .utf8
        case "iso-8859-1": encoding = .isoLatin1
        default: return nil
        }
        var bytes: [UInt8] = []
        var characters = parts[2].utf8.makeIterator()
        while let byte = characters.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = characters.next(), let low = characters.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: encoding)
    }

    /// The header's `name=value` parameters after the disposition type, with quoted values
    /// unquoted.
    private static func parameters(in header: String) -> [(name: String, value: String)] {
        guard let firstSemicolon = header.firstIndex(of: ";") else { return [] }
        var rest = header[header.index(after: firstSemicolon)...]
        var result: [(name: String, value: String)] = []
        while true {
            rest = rest.drop { $0 == " " || $0 == ";" }
            guard let equals = rest.firstIndex(of: "=") else { break }
            let name = rest[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: equals)...].drop { $0 == " " }
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                while let character = rest.popFirst() {
                    if escaped {
                        value.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        value.append(character)
                    }
                }
                rest = rest.drop { $0 != ";" }
            } else {
                let end = rest.firstIndex(of: ";") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            result.append((name, value))
        }
        return result
    }
}
