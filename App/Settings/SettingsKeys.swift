import DowlioConnect
import DowlioCore
import DowlioLibrary
import Foundation

enum SettingsKey {
    static let downloadFolder = "downloadFolder"
    static let sortsIntoCategoryFolders = "sortsIntoCategoryFolders"
    static let nameConflictPolicy = "nameConflictPolicy"
    static let connections = "connections"
    static let downloadsAtOnce = "downloadsAtOnce"
    static let opensAllConnectionsAtOnce = "opensAllConnectionsAtOnce"
    static let retries = "retries"
    static let takesOverSlowSegments = "takesOverSlowSegments"
    static let showsInMenuBar = "showsInMenuBar"
    static let showsInDock = "showsInDock"
    static let startsInMenuBar = "startsInMenuBar"
    static let notifiesWhenFinished = "notifiesWhenFinished"
    static let thenAction = "thenAction"
    static let hasSeenWelcome = "hasSeenWelcome"
    static let catchesDownloads = "catchesDownloads"
    static let neverCatchSites = "neverCatchSites"
}

extension UserDefaults {
    var downloadSettings: DownloadSettings {
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var settings = DownloadSettings(folder: string(forKey: SettingsKey.downloadFolder).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? fallback)
        settings.sortsIntoCategoryFolders = bool(forKey: SettingsKey.sortsIntoCategoryFolders)
        settings.nameConflictPolicy = string(forKey: SettingsKey.nameConflictPolicy).flatMap(NameConflictPolicy.init(rawValue:)) ?? .keepBoth
        settings.connections = integer(SettingsKey.connections) ?? settings.connections
        settings.downloadsAtOnce = integer(SettingsKey.downloadsAtOnce) ?? settings.downloadsAtOnce
        settings.openExtraConnections = bool(forKey: SettingsKey.opensAllConnectionsAtOnce) ? .allAtOnce : .afterFirstConnectionStarts
        settings.retries = integer(SettingsKey.retries) ?? settings.retries
        settings.takesOverSlowSegments = flag(SettingsKey.takesOverSlowSegments) ?? false
        return settings
    }

    var presence: Presence {
        Presence(
            menuBar: flag(SettingsKey.showsInMenuBar) ?? true,
            dock: flag(SettingsKey.showsInDock) ?? true,
            startsInMenuBar: flag(SettingsKey.startsInMenuBar) ?? false
        )
    }

    var catchPreferences: CatchPreferences {
        get {
            CatchPreferences(catches: flag(SettingsKey.catchesDownloads) ?? true, neverCatch: stringArray(forKey: SettingsKey.neverCatchSites) ?? [])
        }
        set {
            set(newValue.catches, forKey: SettingsKey.catchesDownloads)
            set(newValue.neverCatch, forKey: SettingsKey.neverCatchSites)
        }
    }

    /// `nil` when unset. Values can arrive as text, as from a launch argument, so the defaults
    /// system converts them.
    private func integer(_ key: String) -> Int? {
        object(forKey: key) == nil ? nil : integer(forKey: key)
    }

    private func flag(_ key: String) -> Bool? {
        object(forKey: key) == nil ? nil : bool(forKey: key)
    }
}
