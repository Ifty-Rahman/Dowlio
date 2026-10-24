import AppKit

/// For checking the interface by hand without touching the real History: debug builds read a
/// support folder, a download folder and links to add from the environment.
enum DebugLaunch {
    static var supportFolder: URL? { folder("DOWLIO_DEBUG_SUPPORT_FOLDER") }
    static var downloadsFolder: URL? { folder("DOWLIO_DEBUG_DOWNLOADS_FOLDER") }

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

    /// Whether any debug switch is set, so release builds skip the launch-time checks entirely.
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("DOWLIO_DEBUG_") }
        #else
        false
        #endif
    }

    static var showsInspector: Bool { flag("DOWLIO_DEBUG_SHOW_INSPECTOR") }
    static var togglesSidebar: Bool { flag("DOWLIO_DEBUG_TOGGLE_SIDEBAR") }
    static var opensPopover: Bool { flag("DOWLIO_DEBUG_OPEN_POPOVER") }
    static var opensSettings: Bool { flag("DOWLIO_DEBUG_OPEN_SETTINGS") }
    static var opensOnboardingSetup: Bool { flag("DOWLIO_DEBUG_ONBOARDING_SETUP") }

    static var quickAddLink: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOWLIO_DEBUG_QUICK_ADD_LINK"]
        #else
        nil
        #endif
    }

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
