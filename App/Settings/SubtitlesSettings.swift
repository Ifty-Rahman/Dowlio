import DowlioMedia
import SwiftUI

struct SubtitlesSection: View {
    @AppStorage(SettingsKey.downloadsSubtitles) private var downloads = false
    @State private var languages = UserDefaults.standard.subtitlePreference.languages
    @State private var selected: String?
    private static let listHeight: CGFloat = 104

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
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
                Text("Languages, in order. The first one is preferred.")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(Array(languages.enumerated()), id: \.element) { index, code in
                            HStack(spacing: DowlioDesign.Spacing.sm) {
                                Text(verbatim: "\(index + 1)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 14, alignment: .trailing)
                                Text(Self.name(of: code))
                            }
                            .tag(code)
                        }
                        .onMove(perform: move)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: Self.listHeight)
                    Divider()
                    HStack(spacing: 0) {
                        Menu {
                            ForEach(Self.choices.filter { !languages.contains($0) }, id: \.self) { code in
                                Button(Self.name(of: code)) { add(code) }
                            }
                        } label: {
                            Image(systemName: "plus").frame(width: 24, height: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add a language")
                        .accessibilityLabel("Add Language")
                        Divider().frame(height: 16)
                        Button {
                            if let selected { remove(selected) }
                        } label: {
                            Image(systemName: "minus").frame(width: 24, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .disabled(selected == nil || languages.count == 1)
                        .help("Remove the selected language")
                        .accessibilityLabel("Remove Language")
                        Spacer()
                        Text("Drag to reorder")
                            .font(DowlioDesign.TypeRole.detail)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, DowlioDesign.Spacing.sm)
                    }
                    .padding(.horizontal, DowlioDesign.Spacing.xs)
                    .padding(.vertical, 2)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
                .overlay(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested).strokeBorder(Color(nsColor: .separatorColor)))
            }
            .disabled(!downloads)
        } header: {
            Text("Subtitles")
        }
        .onAppear { languages = UserDefaults.standard.subtitlePreference.languages }
    }

    private func move(from source: IndexSet, to destination: Int) {
        languages.move(fromOffsets: source, toOffset: destination)
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
        selected = code
        save()
    }

    private func remove(_ code: String) {
        guard languages.count > 1, let index = languages.firstIndex(of: code) else { return }
        languages.remove(at: index)
        selected = languages[min(index, languages.count - 1)]
        save()
    }

    private func save() {
        UserDefaults.standard.set(languages, forKey: SettingsKey.subtitleLanguages)
    }
}
