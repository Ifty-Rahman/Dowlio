import DowlioConnect
import DowlioCore
import DowlioLibrary
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let model: AppModel
    @AppStorage("settingsTab") private var tab = "general"
    private static let tabs: Set<String> = ["general", "downloads", "connections", "browsers"]

    var body: some View {
        TabView(selection: Binding(get: { Self.tabs.contains(tab) ? tab : "general" }, set: { tab = $0 })) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            DownloadsSettings(model: model).tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag("downloads")
            ConnectionsSettings(model: model).tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("connections")
            BrowsersSettings(model: model)
                .tabItem { Label("Browsers", systemImage: "globe") }
                .tag("browsers")
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .hidingToolbarBackground()
        .background(SettingsWindowBehavior(model: model))
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.notifiesWhenFinished) private var notifies = true
    @AppStorage(SettingsKey.notifiesOnProblems) private var notifiesOnProblems = true
    @AppStorage(SettingsKey.thenAction) private var thenAction = ThenAction.nothing
    @State private var permission = NotificationPermission()

    var body: some View {
        Form {
            Section {
                PresenceToggles(model: model)
            }
            Section("When a download finishes") {
                Toggle("Show a notification", isOn: $notifies)
                if notifies && permission.needsAttention { NotificationPermissionRow(permission: permission) }
                Picker("Then", selection: $thenAction) {
                    ForEach(ThenAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("When a download fails or can't resume") {
                Toggle("Show a notification", isOn: $notifiesOnProblems)
            }
            UpdateSettings(updater: model.updater)
        }
        .settingsForm()
        .task { await permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permission.refresh() }
        }
    }
}

private struct UpdateSettings: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section("Updates") {
            LabeledContent {
                Button("Check Now") { updater.checkNow() }
                    .disabled(!updater.canCheck)
            } label: {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            }
        }
    }
}

/// Open at login, Show in menu bar and Show in Dock, shared by Settings and onboarding so the
/// "never both off" rule holds in both.
struct PresenceToggles: View {
    let model: AppModel
    @AppStorage(SettingsKey.showsInMenuBar) private var menuBar = true
    @AppStorage(SettingsKey.showsInDock) private var dock = true
    @AppStorage(SettingsKey.startsInMenuBar) private var startsInMenuBar = false
    @State private var presenceNote: String?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Toggle("Open Dowlio at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
        if let loginProblem {
            Text(loginProblem).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
        }
        Toggle(isOn: Binding(get: { startsInMenuBar }, set: { set(.startsInMenuBar, $0) })) {
            HStack(spacing: DowlioDesign.Spacing.xs) {
                Text("Start in the menu bar")
                InfoButton(
                    topic: "Start in the menu bar",
                    text: "Dowlio opens with no window. Open Dowlio in the menu bar brings it up."
                )
            }
        }
        Toggle("Show in menu bar", isOn: Binding(get: { menuBar }, set: { set(.menuBar, $0) }))
            .disabled(!presence.canChangeMenuBar)
            .help(presence.canChangeMenuBar ? "" : "Dowlio starts in the menu bar, so its icon stays there.")
        Toggle("Show in Dock", isOn: Binding(get: { dock }, set: { set(.dock, $0) }))
        if let presenceNote {
            Text(presenceNote).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
        }
    }

    private var presence: Presence {
        Presence(menuBar: menuBar, dock: dock, startsInMenuBar: startsInMenuBar)
    }

    private func set(_ which: Presence.Switch, _ isOn: Bool) {
        let result = presence.setting(which, to: isOn)
        menuBar = result.presence.menuBar
        dock = result.presence.dock
        startsInMenuBar = result.presence.startsInMenuBar
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
    @AppStorage(SettingsKey.videoQualityCap) private var videoQualityCap = 0
    @AppStorage(SettingsKey.prefersH264) private var prefersH264 = true
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
            Picker("If a file with the same name exists", selection: Binding(get: { policy }, set: { choosePolicy($0) })) {
                Text("Keep both").tag(NameConflictPolicy.keepBoth.rawValue)
                Text("Replace").tag(NameConflictPolicy.replace.rawValue)
                Text("Skip").tag(NameConflictPolicy.skip.rawValue)
            }
            Picker("Video quality", selection: $videoQualityCap) {
                Text("Best available").tag(0)
                ForEach(VideoQuality.caps, id: \.self) { cap in
                    Text(verbatim: "Up to \(cap)p").tag(cap)
                }
            }
            Toggle("Prefer H.264 MP4", isOn: $prefersH264)
                .help("H.264 MP4 plays everywhere, including QuickTime, even when a higher resolution is offered in VP9 or AV1.")
            LabeledContent("History") {
                Button("Clear History…") { confirmingClear = true }
            }
            SubtitlesSection()
            Section {
                ToolsRows(tools: model.toolsModel)
            } header: {
                ToolsInfoTitle()
            }
        }
        .settingsForm()
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
    @AppStorage(SettingsKey.takesOverSlowSegments) private var takesOverSlowSegments = false
    @State private var explainsTakingOver = false

    var body: some View {
        Form {
            LabeledContent {
                HStack(spacing: DowlioDesign.Spacing.sm) {
                    Slider(value: Binding(get: { Double(connections) }, set: { connections = Int($0.rounded()) }), in: 1...16, step: 1)
                        .frame(width: 160)
                        .accessibilityLabel("Connections per download")
                        .accessibilityValue("\(connections)")
                    Text("\(connections)").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                }
            } label: {
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    Text("Connections per download")
                    InfoButton(
                        topic: "Connections per download",
                        text: "8 to 16 is fastest. Servers that allow fewer are detected automatically."
                    )
                }
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
            LabeledContent {
                Toggle("Take over slow segments", isOn: $takesOverSlowSegments).labelsHidden().toggleStyle(.switch)
            } label: {
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    Text("Take over slow segments")
                    Button { explainsTakingOver.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("What this does")
                    .accessibilityLabel("About taking over slow segments")
                    .popover(isPresented: $explainsTakingOver, arrowEdge: .bottom) {
                        TakingOverExplanation()
                    }
                }
            }
            LabeledContent("Retry a failed connection") {
                HStack {
                    Text(retries == 1 ? "1 time" : "\(retries) times").monospacedDigit()
                    Stepper("Retry a failed connection", value: $retries, in: 0...10).labelsHidden()
                }
            }
        }
        .settingsForm()
    }
}

private struct BrowsersSettings: View {
    @Bindable var model: AppModel
    @AppStorage(SettingsKey.usesBrowserSignIn) private var usesBrowserSignIn = false

    var body: some View {
        Form {
            if let setup = model.browserSetup {
                Section {
                    BrowsersList(setup: setup)
                }
            }
            Section {
                SendShortcutRecorder()
            }
            Section {
                Toggle(isOn: $usesBrowserSignIn) {
                    HStack(spacing: DowlioDesign.Spacing.xs) {
                        Text("Use my browser's sign-in for pasted links")
                        InfoButton(
                            topic: "Browser sign-in",
                            text: "When you paste a link, Dowlio asks the browser in front, or the one you used with Dowlio last, for that site's cookies, so videos behind a sign-in work without sending the page. The cookies stay in memory for that link and its download. Dowlio doesn't save them."
                        )
                    }
                }
            }
            Section {
                Toggle(isOn: $model.catchPreferences.catches) {
                    HStack(spacing: DowlioDesign.Spacing.xs) {
                        Text("Catch downloads")
                        InfoButton(
                            topic: "Catch downloads",
                            text: "Downloads you start in a browser with Dowlio Connect finish in Dowlio. When Dowlio can't take one, the browser keeps it."
                        )
                    }
                }
            }
            Section {
                if model.catchPreferences.neverCatch.isEmpty {
                    Text("No sites yet. Add one from Dowlio Connect's popup.")
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.catchPreferences.neverCatch, id: \.self) { site in
                        LabeledContent(site) {
                            Button("Remove") { model.catchPreferences.catchAgain(site) }
                                .accessibilityLabel("Remove \(site)")
                        }
                    }
                }
            } header: {
                Text("Never catch downloads on")
            }
        }
        .settingsForm()
    }
}

private extension View {
    @ViewBuilder
    func hidingToolbarBackground() -> some View {
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsForm() -> some View {
        let form = formStyle(.grouped).scrollIndicators(.never)
        if #available(macOS 26, *) {
            form.scrollEdgeEffectHidden(true, for: .top)
        } else {
            form
        }
    }
}

private struct TakingOverExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text("Take over slow segments").font(DowlioDesign.TypeRole.heading)
            Text("Dowlio splits each download into segments, one per connection. Some connections are slower than others, so a download can end up waiting on one slow segment.")
            Text("With this on, a connection that finishes its own segment early takes over half of the slowest segment's remaining work, so the download finishes sooner. A download can be split this way into at most 32 segments.")
            Text("Leave it off if a server limits how many requests it accepts, or if you'd rather each connection keep its own segment.")
        }
        .font(DowlioDesign.TypeRole.detail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(DowlioDesign.Spacing.lg)
    }
}

struct InfoButton: View {
    let topic: String
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(topic)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(DowlioDesign.TypeRole.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(DowlioDesign.Spacing.lg)
        }
    }
}
