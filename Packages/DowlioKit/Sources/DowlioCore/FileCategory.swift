import Foundation

/// What kind of file a download is, in the sense of `GLOSSARY.md`. The extension decides first and
/// the content type second. A file that matches neither has no category.
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case video
    case audio
    case documents
    case archives
    case appsAndDiskImages

    public init?(fileName: String, contentType: String?) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if let category = Self.byExtension[fileExtension] {
            self = category
        } else if let category = contentType.flatMap(Self.category(forContentType:)) {
            self = category
        } else {
            return nil
        }
    }

    /// The folder "Sort into category folders" saves into, and the name the sidebar shows.
    public var folderName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .documents: "Documents"
        case .archives: "Archives"
        case .appsAndDiskImages: "Apps & Disk Images"
        }
    }

    private static let byExtension: [String: FileCategory] = {
        let extensions: [FileCategory: [String]] = [
            .video: ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts"],
            .audio: ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus", "wma", "alac"],
            .documents: [
                "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "md",
                "csv", "pages", "numbers", "key", "epub",
            ],
            .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma", "z"],
            .appsAndDiskImages: ["dmg", "pkg", "mpkg", "iso", "img", "app", "xip", "exe", "msi", "deb", "rpm", "apk", "appimage"],
        ]
        var map: [String: FileCategory] = [:]
        for (category, list) in extensions {
            for fileExtension in list { map[fileExtension] = category }
        }
        return map
    }()

    private static func category(forContentType contentType: String) -> FileCategory? {
        let mimeType = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return byContentType[mimeType]
    }

    private static let byContentType: [String: FileCategory] = [
        "application/pdf": .documents,
        "text/plain": .documents,
        "text/csv": .documents,
        "text/markdown": .documents,
        "application/rtf": .documents,
        "application/msword": .documents,
        "application/vnd.ms-excel": .documents,
        "application/vnd.ms-powerpoint": .documents,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .documents,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .documents,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": .documents,
        "application/epub+zip": .documents,
        "application/zip": .archives,
        "application/x-zip-compressed": .archives,
        "application/gzip": .archives,
        "application/x-gzip": .archives,
        "application/x-tar": .archives,
        "application/x-7z-compressed": .archives,
        "application/vnd.rar": .archives,
        "application/x-rar-compressed": .archives,
        "application/x-bzip2": .archives,
        "application/x-xz": .archives,
        "application/zstd": .archives,
        "application/x-apple-diskimage": .appsAndDiskImages,
        "application/x-iso9660-image": .appsAndDiskImages,
        "application/vnd.apple.installer+xml": .appsAndDiskImages,
        "application/x-msdownload": .appsAndDiskImages,
        "application/x-msi": .appsAndDiskImages,
        "application/vnd.debian.binary-package": .appsAndDiskImages,
        "application/vnd.android.package-archive": .appsAndDiskImages,
    ]
}
