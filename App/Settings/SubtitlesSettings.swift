import DowlioMedia
import SwiftUI

struct SubtitlesSection: View {
    @AppStorage(SettingsKey.downloadsSubtitles) private var downloads = false
    @State private var languages = UserDefaults.standard.subtitlePreference.languages

    var body: some View {
        Section {
            Toggle(isOn: $downloads) {
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    Text("Download subtitles")
                    InfoButton(
                        topic: "Subtitles",
                        text: "For videos read with yt-dlp, Dowlio puts subtitles in your languages inside the file, so your media player lists them in its subtitle menu. It takes the uploader's subtitles first, then automatic ones, and an automatic translation into your first language only when nothing else exists. Audio downloads never get subtitles."
                    )
                }
            }
            ForEach(languages, id: \.self) { code in
                LabeledContent(Self.name(of: code)) {
                    HStack(spacing: DowlioDesign.Spacing.sm) {
                        Button("Move Up", systemImage: "arrow.up") { moveUp(code) }
                            .disabled(languages.first == code)
                            .help("Prefer \(Self.name(of: code)) over the language above it")
                        Button("Remove", systemImage: "minus.circle") { remove(code) }
                            .disabled(languages.count == 1)
                            .help("Remove \(Self.name(of: code))")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .disabled(!downloads)
            }
            LabeledContent {
                Menu("Add Language") {
                    ForEach(Self.choices.filter { !languages.contains($0) }, id: \.self) { code in
                        Button(Self.name(of: code)) { add(code) }
                    }
                }
                .fixedSize()
            } label: {
                Text("In this order, first one preferred")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
            .disabled(!downloads)
        } header: {
            Text("Subtitles")
        }
        .onAppear { languages = UserDefaults.standard.subtitlePreference.languages }
    }

    private func moveUp(_ code: String) {
        guard let index = languages.firstIndex(of: code), index > 0 else { return }
        languages.swapAt(index, index - 1)
        save()
    }

    private static let choices: [String] = {
        let codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 } + SubtitlePreference.macLanguages)
        return codes.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }()

    private static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func add(_ code: String) {
        languages.append(code)
        save()
    }

    private func remove(_ code: String) {
        languages.removeAll { $0 == code }
        save()
    }

    private func save() {
        UserDefaults.standard.set(languages, forKey: SettingsKey.subtitleLanguages)
    }
}
