import Foundation

enum FileNaming {
    /// The finished file's name, from the final URL after redirects. Ticket 09 adds
    /// `Content-Disposition` and cleaning.
    static func name(for url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? "download" : last
    }
}
