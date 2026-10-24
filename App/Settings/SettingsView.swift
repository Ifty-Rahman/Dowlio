import DowlioCore
import DowlioLibrary
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            DownloadsSettings(model: model).tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag("downloads")
            ConnectionsSettings(model: model).tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("connections")
            ComingSoon(text: "Dowlio uses your Mac's network and proxy settings. More network options come in a later release.")
                .tabItem { Label("Network", systemImage: "network") }
                .tag("network")
            ComingSoon(text: "The Dowlio browser extension, which catches downloads you click in Chrome, Arc, Brave and Edge, comes in a later release.")
                .tabItem { Label("Browsers", systemImage: "globe") }
                .tag("browsers")
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.showsInMenuBar) private var menuBar = true
    @AppStorage(SettingsKey.showsInDock) private var dock = true
    @State private var presenceNote: String?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Toggle("Open Dowlio at login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            if let loginProblem {
                Text(loginProblem).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
            Toggle("Show in menu bar", isOn: Binding(get: { menuBar }, set: { set(.menuBar, $0) }))
            Toggle("Show in Dock", isOn: Binding(get: { dock }, set: { set(.dock, $0) }))
            if let presenceNote {
                Text(presenceNote).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
    }

    private func set(_ which: Presence.Switch, _ isOn: Bool) {
        let result = Presence(menuBar: menuBar, dock: dock).setting(which, to: isOn)
        menuBar = result.presence.menuBar
        dock = result.presence.dock
        presenceNote = result.note
        model.applyPresence()
    }

    private func setOpensAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Dowlio in System Settings › General › Login Items to finish turning this on."
                : nil
        } catch {
            loginProblem = "macOS didn't let Dowlio change this: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct DownloadsSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.downloadFolder) private var folderPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage(SettingsKey.sortsIntoCategoryFolders) private var sortsIntoCategoryFolders = false
    @AppStorage(SettingsKey.nameConflictPolicy) private var policy = NameConflictPolicy.keepBoth.rawValue
    @State private var choosingFolder = false
    @State private var confirmingReplace = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text((folderPath as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { choosingFolder = true }
                }
            }
            Toggle("Sort into category folders", isOn: $sortsIntoCategoryFolders)
            Picker("If a file with the same name exists", selection: Binding(get: { policy }, set: choosePolicy)) {
                Text("Keep both").tag(NameConflictPolicy.keepBoth.rawValue)
                Text("Replace").tag(NameConflictPolicy.replace.rawValue)
                Text("Skip").tag(NameConflictPolicy.skip.rawValue)
            }
            Section {
                LabeledContent("History") {
                    Button("Clear History…") { confirmingClear = true }
                }
            } footer: {
                Text("Removes completed downloads from the list. The files stay where they are.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { folderPath = folder.path }
        }
        .alert("Replace existing files?", isPresented: $confirmingReplace) {
            Button("Replace", role: .destructive) { policy = NameConflictPolicy.replace.rawValue }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new download with the same name as a file in its folder will overwrite that file.")
        }
        .alert("Clear History?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearCompleted() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed downloads leave the list. Their files stay where they are.")
        }
    }

    private func choosePolicy(_ value: String) {
        if value == NameConflictPolicy.replace.rawValue, policy != value {
            confirmingReplace = true
        } else {
            policy = value
        }
    }
}

private struct ConnectionsSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.connections) private var connections = 8
    @AppStorage(SettingsKey.downloadsAtOnce) private var downloadsAtOnce = 3
    @AppStorage(SettingsKey.opensAllConnectionsAtOnce) private var allAtOnce = false
    @AppStorage(SettingsKey.retries) private var retries = 5

    var body: some View {
        Form {
            Section {
                LabeledContent("Connections per download") {
                    Text("\(connections)").monospacedDigit()
                }
                Slider(value: Binding(get: { Double(connections) }, set: { connections = Int($0.rounded()) }), in: 1...16, step: 1)
                    .accessibilityLabel("Connections per download")
                    .accessibilityValue("\(connections)")
            } footer: {
                Text("8 to 16 is fastest. Servers that allow fewer are detected automatically.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Downloads at once") {
                HStack {
                    Text("\(downloadsAtOnce)").monospacedDigit()
                    Stepper("Downloads at once", value: Binding(get: { downloadsAtOnce }, set: {
                        downloadsAtOnce = $0
                        model.applyDownloadsAtOnce()
                    }), in: 1...10)
                    .labelsHidden()
                }
            }
            Picker("Open extra connections", selection: $allAtOnce) {
                Text("After the first connection starts").tag(false)
                Text("All at once").tag(true)
            }
            LabeledContent("Retry a failed connection") {
                HStack {
                    Text(retries == 1 ? "1 time" : "\(retries) times").monospacedDigit()
                    Stepper("Retry a failed connection", value: $retries, in: 0...10).labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
    }
}

private struct ComingSoon: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DowlioDesign.TypeRole.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(DowlioDesign.Spacing.xxl)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}
