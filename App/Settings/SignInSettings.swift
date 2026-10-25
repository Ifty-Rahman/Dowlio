import DowlioConnect
import SwiftUI

struct SignInSettings: View {
    @Bindable var model: AppModel
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                Toggle("Use my browser's sign-in for downloads", isOn: $model.catchPreferences.sharesSignIn)
            } footer: {
                Text("When a download starts in your browser or you send a link, Dowlio Connect passes along that site's cookies, so sites that need you signed in work. Dowlio keeps them in memory for that download only.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
            Section {
                if rows.isEmpty {
                    Text("Sites Dowlio has used your sign-in for appear here.")
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        SignInRow(row: row, model: model)
                    }
                }
            } header: {
                Text("Sites")
            }
            Section {
                HStack {
                    TextField("example.com", text: $newSite)
                        .onSubmit(block)
                    Button("Block", action: block)
                        .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Never use my sign-in on")
            } footer: {
                Text("A blocked site and its subdomains get no cookies from Dowlio Connect.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
    }

    private var rows: [Row] {
        let blocked = Set(model.catchPreferences.noSignIn)
        var rows = model.signInLog.sites.map { Row(host: $0.host, detail: Self.detail($0), isBlocked: blocked.contains($0.host)) }
        for host in model.catchPreferences.noSignIn where !rows.contains(where: { $0.host == host }) {
            rows.append(Row(host: host, detail: "Blocked", isBlocked: true))
        }
        return rows
    }

    private func block() {
        model.catchPreferences.noSignInOn(newSite)
        newSite = ""
    }

    private static func detail(_ site: SignInSite) -> String {
        let uses = site.uses == 1 ? "1 download" : "\(site.uses) downloads"
        return "\(uses) · last \(site.lastUsed.formatted(.relative(presentation: .named)))"
    }

    struct Row: Identifiable {
        let host: String
        let detail: String
        let isBlocked: Bool
        var id: String { host }
    }
}

private struct SignInRow: View {
    let row: SignInSettings.Row
    let model: AppModel

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.host)
                Label(row.isBlocked ? "Blocked" : row.detail, systemImage: row.isBlocked ? "nosign" : "key.fill")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(row.isBlocked ? .orange : .secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if row.isBlocked {
                Button("Unblock") { model.catchPreferences.signInAgain(row.host) }
                    .accessibilityLabel("Unblock \(row.host)")
            } else {
                Button("Block") { model.catchPreferences.noSignInOn(row.host) }
                    .accessibilityLabel("Block \(row.host)")
            }
            Button("Remove") { model.forgetSignIn(on: row.host) }
                .accessibilityLabel("Remove \(row.host)")
        }
    }
}
