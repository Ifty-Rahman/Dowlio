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
        .task {
            await setup.refresh(rescanning: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await setup.refresh()
            }
        }
        .sheet(item: Bindable(setup).guide) { row in
            AddGuide(row: row, folderName: setup.folderName) { setup.guide = nil }
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
                case .needsReload:
                    Button("Reload") { setup.reload(row) }
                case .notConnected:
                    if row.appURL != nil { Button("Open the browser") { setup.open(row) } }
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
    let folderName: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            Text("Finish adding Dowlio Connect to \(row.name)")
                .font(DowlioDesign.TypeRole.title)
                .accessibilityAddTraits(.isHeader)
            Text("Dowlio opened \(row.name)'s extensions page and showed the \(folderName) folder in Finder.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
                Text("1. Turn on Developer mode, at the top right of the extensions page.")
                Text("2. Click Load unpacked.")
                Text("3. Choose the \(folderName) folder.")
            }
            Text("Dowlio then asks you to allow \(row.name). Once you do, the row turns Connected.")
                .foregroundStyle(.secondary)
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
        .frame(width: 440)
    }
}

private extension BrowserState {
    var word: String {
        switch self {
        case .connected: "Connected"
        case .needsReload: "Needs reload"
        case .notConnected: "Not connected"
        case .notInstalled: "Not installed"
        }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .needsReload: "arrow.clockwise.circle"
        case .notConnected: "exclamationmark.circle"
        case .notInstalled: "plus.circle"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .needsReload: .accentColor
        case .notConnected: .orange
        case .notInstalled: .secondary
        }
    }
}
