import AppKit
import DowlioConnect
import SwiftUI

struct BrowsersList: View {
    let setup: BrowserSetup

    var body: some View {
        Group {
            if setup.rows.isEmpty {
                Text("Dowlio didn't find a Chromium browser, such as Chrome, Arc, Brave or Edge, in your Applications folders.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(setup.rows) { row in
                    BrowserRowView(row: row, setup: setup)
                }
            }
            HStack {
                Text("Missing a browser? Dowlio finds the Chromium browsers it knows. Any other Chromium browser can still connect.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Add Another Browser…") { setup.addOther() }
            }
            HStack {
                Spacer()
                if setup.isScanning { ProgressView().controlSize(.small) }
                Button("Scan for Browsers") { Task { await setup.refresh(rescanning: true) } }
                    .disabled(setup.isScanning)
            }
            if let failure = setup.addFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.red)
            }
        }
        .task { await setup.watch() }
        .task {
            await setup.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await setup.refresh()
            }
        }
        .sheet(item: Bindable(setup).guide) { row in
            AddGuide(
                name: setup.guideBrowserName, path: setup.folderPath, connected: setup.guideIsConnected,
                openExtensions: row.appURL == nil ? nil : { setup.openExtensionsPage(of: row) }
            ) { setup.guide = nil }
        }
    }
}

private struct BrowserRowView: View {
    let row: BrowserRow
    let setup: BrowserSetup

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                BrowserIcon(appURL: row.appURL)
                HStack(spacing: DowlioDesign.Spacing.sm) {
                    Text(row.name)
                    Label(row.state.word, systemImage: row.state.symbol)
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(row.state.color)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                switch row.state {
                case .connected:
                    testButton
                case .connecting:
                    ProgressView().controlSize(.small)
                case .needsReload:
                    Button("Reload") { setup.reload(row) }
                case .notConnected:
                    Button("Add") { setup.add(row) }
                    testButton
                case .notInstalled:
                    Button("Add") { setup.add(row) }
                }
            }
            if let result = setup.testResults[row.name] {
                Text(result)
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testButton: some View {
        Button(setup.testing.contains(row.name) ? "Testing…" : "Test") { setup.test(row) }
            .disabled(setup.testing.contains(row.name))
    }

}

private struct BrowserIcon: View {
    let appURL: URL?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 20

    var body: some View {
        Group {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

private struct AddGuide: View {
    let name: String
    let path: String
    let connected: Bool
    let openExtensions: (() -> Void)?
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        Group {
            if connected {
                connectedBody
            } else {
                steps
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DowlioDesign.Spacing.xxl)
        .frame(width: connected ? 320 : 480)
        .task(id: connected) {
            guard connected else { return }
            try? await Task.sleep(for: .seconds(2))
            done()
        }
    }

    private var connectedBody: some View {
        VStack(spacing: DowlioDesign.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Connected to \(name)")
                .font(DowlioDesign.TypeRole.title)
                .accessibilityAddTraits(.isHeader)
            Text("You can now send pages from \(name) to Dowlio.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            Text("Add Dowlio Connect to \(name)")
                .font(DowlioDesign.TypeRole.title)
                .accessibilityAddTraits(.isHeader)
            Text("Follow these steps. Dowlio stays open here, and this window closes when \(name) is connected.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: DowlioDesign.Spacing.sm) {
                Text(path)
                    .font(DowlioDesign.TypeRole.detail.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    copied = true
                }
            }
            .padding(DowlioDesign.Spacing.md)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
                step(1, "Click Copy path above.")
                if openExtensions != nil {
                    step(2, "Click Open extensions page below. It opens in \(name).")
                } else {
                    step(2, "Open the extensions page of \(name). Type chrome:// followed by extensions in its address bar, or find Extensions in its menu.")
                }
                step(3, "In \(name), turn on Developer mode, at the top right of the extensions page.")
                step(4, "Click Load unpacked.")
                step(5, "In the file window, press ⌘⇧G, paste the path with ⌘V, and press Return.")
                step(6, "Click Select.")
                step(7, "Dowlio asks you to allow \(name). Click Allow, and this window shows you're connected.")
            }
            HStack {
                if let openExtensions { Button("Open extensions page", action: openExtensions) }
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DowlioDesign.Spacing.sm) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension BrowserState {
    var word: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .needsReload: "Needs reload"
        case .notConnected: "Not connected"
        case .notInstalled: "Not installed"
        }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .needsReload: "arrow.clockwise.circle"
        case .notConnected: "exclamationmark.circle"
        case .notInstalled: "plus.circle"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .accentColor
        case .needsReload: .accentColor
        case .notConnected: .orange
        case .notInstalled: .secondary
        }
    }
}
