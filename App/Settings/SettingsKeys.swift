import DowlioCore
import DowlioLibrary
import Foundation

/// Where each setting lives in the user defaults.
enum SettingsKey {
    static let downloadFolder = "downloadFolder"
    static let sortsIntoCategoryFolders = "sortsIntoCategoryFolders"
    static let nameConflictPolicy = "nameConflictPolicy"
    static let connections = "connections"
    static let downloadsAtOnce = "downloadsAtOnce"
    static let opensAllConnectionsAtOnce = "opensAllConnectionsAtOnce"
    static let retries = "retries"
    static let showsInMenuBar = "showsInMenuBar"
    static let showsInDock = "showsInDock"
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
        return settings
    }

    var presence: Presence {
        Presence(menuBar: flag(SettingsKey.showsInMenuBar) ?? true, dock: flag(SettingsKey.showsInDock) ?? true)
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
