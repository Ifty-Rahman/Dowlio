import Foundation

public enum TestMedia {
    public static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: "Media/\(name)", withExtension: nil)
    }

    public static func data(_ name: String) throws -> Data {
        guard let url = url(name) else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }
}
