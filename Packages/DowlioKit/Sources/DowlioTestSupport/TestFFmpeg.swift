import Foundation

public enum TestFFmpeg {
    public static var helper: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOWLIO_FFMPEG"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static var isAvailable: Bool { helper != nil }

    public struct Description: Equatable, Sendable {
        public var streams: [String]
        public var duration: Double?
        public var chapters: Int
        public var hasCoverArt: Bool
        public var subtitleLanguages: [String]
    }

    public static func describe(_ file: URL) throws -> Description {
        guard let helper else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["-hide_banner", "-nostdin", "-i", file.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = text.components(separatedBy: "\n")
        let streamLines = lines.filter { $0.contains("Stream #0:") }
        let streams = streamLines.compactMap { line -> String? in
            guard let kind = ["Video", "Audio", "Subtitle"].first(where: { line.contains(": \($0): ") }) else { return nil }
            let after = line.components(separatedBy: ": \(kind): ")[1]
            let codec = after.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
            return "\(kind.lowercased()):\(codec)"
        }
        let duration = lines.first { $0.contains("Duration: ") }.flatMap { line -> Double? in
            let value = line.components(separatedBy: "Duration: ")[1].prefix(11)
            let parts = value.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        let subtitleLanguages = streamLines.filter { $0.contains(": Subtitle: ") }.compactMap { line -> String? in
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { return nil }
            return String(line[line.index(after: open)..<close])
        }
        return Description(
            streams: streams,
            duration: duration,
            chapters: lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Chapter #") }.count,
            hasCoverArt: streamLines.contains { $0.contains("(attached pic)") },
            subtitleLanguages: subtitleLanguages
        )
    }
}
