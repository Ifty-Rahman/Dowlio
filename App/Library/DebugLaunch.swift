import AppKit

/// For checking the interface by hand without touching the real History: debug builds read a
/// support folder, a download folder and links to add from the environment.
enum DebugLaunch {
    static var supportFolder: URL? { folder("DOWLIO_DEBUG_SUPPORT_FOLDER") }
    static var downloadsFolder: URL? { folder("DOWLIO_DEBUG_DOWNLOADS_FOLDER") }

    /// Hands over `DOWLIO_DEBUG_ADD_LINKS` two seconds after launch, as if the user added them.
    @MainActor
    static func addLinks(_ add: @escaping @MainActor (String) -> Void) {
        #if DEBUG
        guard let links = ProcessInfo.processInfo.environment["DOWLIO_DEBUG_ADD_LINKS"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            add(links.replacingOccurrences(of: " ", with: "\n"))
        }
        #endif
    }

    /// Opens the New Download sheet with `DOWLIO_DEBUG_SHEET_LINKS` six seconds after launch, then
    /// presses Download two seconds later.
    @MainActor
    static func useSheet(open: @escaping @MainActor (String) -> Void, download: @escaping @MainActor () -> Void) {
        #if DEBUG
        guard let links = ProcessInfo.processInfo.environment["DOWLIO_DEBUG_SHEET_LINKS"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            open(links.replacingOccurrences(of: " ", with: "\n"))
            try? await Task.sleep(for: .seconds(2))
            download()
        }
        #endif
    }

    static var showsInspector: Bool { flag("DOWLIO_DEBUG_SHOW_INSPECTOR") }
    static var togglesSidebar: Bool { flag("DOWLIO_DEBUG_TOGGLE_SIDEBAR") }

    /// Sets the library window's width from `DOWLIO_DEBUG_WINDOW_WIDTH`, as a drag would.
    @MainActor
    static func applyWindowWidth() {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["DOWLIO_DEBUG_WINDOW_WIDTH"], let width = Double(value),
              let window = NSApp.windows.first(where: \.isVisible) else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        #endif
    }

    private static func flag(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[name] == "1"
        #else
        false
        #endif
    }

    private static func folder(_ name: String) -> URL? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name].map { URL(filePath: $0, directoryHint: .isDirectory) }
        #else
        nil
        #endif
    }
}
