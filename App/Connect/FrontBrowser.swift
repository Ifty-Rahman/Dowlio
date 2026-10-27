import AppKit
import Carbon
import DowlioConnect

enum FrontBrowser {
    static var frontApp: FrontApp? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let name = front.bundleURL.flatMap { PeerProcess.appName(forExecutable: $0.path) } ?? front.localizedName
        return name.map { FrontApp(name: $0, bundleID: front.bundleIdentifier) }
    }

    static func read(_ app: FrontApp) async -> AppleEventReply? {
        guard let bundleID = app.bundleID, let source = ScriptableBrowsers.script(for: bundleID) else { return nil }
        return await Task.detached {
            guard askPermission(bundleID) != OSStatus(errAEEventNotPermitted) else { return .refused }
            return run(source)
        }.value
    }

    private static func askPermission(_ bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
    }

    private static func run(_ source: String) -> AppleEventReply {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == Int(errAEEventNotPermitted) { return .refused }
        return ScriptableBrowsers.reply(result?.stringValue ?? "")
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
