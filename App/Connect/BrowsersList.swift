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
            if let failure = setup.addFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.red)
            }
        }
        .task { await setup.watch() }
        .task {
            await setup.refresh(rescanning: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await setup.refresh()
            }
        }
        .sheet(item: Bindable(setup).guide) { row in
            AddGuide(row: row, path: setup.folderPath) { setup.guide = nil }
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
                VStack(alignment: .leading, spacing: 2) {
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
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

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
    let row: BrowserRow
    let path: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            Text("Add Dowlio Connect to \(row.name)")
                .font(DowlioDesign.TypeRole.title)
                .accessibilityAddTraits(.isHeader)
            Text("Dowlio opened \(row.name)'s extensions page. Follow these steps in \(row.name).")
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
                step(2, "In \(row.name), turn on Developer mode, at the top right of the extensions page.")
                step(3, "Click Load unpacked.")
                step(4, "In the file window, press ⌘⇧G, paste the path with ⌘V, and press Return.")
                step(5, "Click Select.")
                step(6, "Dowlio asks you to allow \(row.name). Click Allow, and the row turns Connected.")
            }
            Text("If the extensions page didn't open, type chrome://extensions in \(row.name)'s address bar and press Return.")
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DowlioDesign.Spacing.xxl)
        .frame(width: 480)
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
