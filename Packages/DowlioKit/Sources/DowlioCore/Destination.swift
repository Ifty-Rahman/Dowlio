import Foundation

/// Where a download's finished file goes.
public enum Destination: Equatable, Sendable {
    case folder(URL)
    /// Into the folder for the file's Category inside this one, or into this one when the file
    /// has no Category. The engine decides after its probe.
    case categoryFolders(under: URL)

    public func folder(forFileNamed fileName: String, contentType: String?) -> URL {
        switch self {
        case .folder(let folder):
            folder
        case .categoryFolders(let root):
            FileCategory(fileName: fileName, contentType: contentType)
                .map { root.appending(path: $0.folderName, directoryHint: .isDirectory) } ?? root
        }
    }

    /// The folder shown before the probe answers.
    public var root: URL {
        switch self {
        case .folder(let folder), .categoryFolders(let folder): folder
        }
    }
}
