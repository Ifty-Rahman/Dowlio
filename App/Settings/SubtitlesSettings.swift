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
                    LanguageList(languages: $languages, selected: $selected, height: Self.listHeight, name: Self.name, changed: save)
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

private struct LanguageList: View {
    @Binding var languages: [String]
    @Binding var selected: String?
    let height: CGFloat
    let name: (String) -> String
    let changed: () -> Void
    @State private var scrolled: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var dragging: String?

    private static let space = "languages"
    private static let rowHeight: CGFloat = 26
    private static let barWidth: CGFloat = 6
    private static let barInset: CGFloat = 4

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(languages.enumerated()), id: \.element) { index, code in
                    row(index, code)
                }
            }
            .padding(.vertical, Self.barInset)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                scrolled = -frame.minY
                contentHeight = frame.height
            }
        }
        .coordinateSpace(name: Self.space)
        .scrollIndicators(.never)
        .frame(height: height)
        .overlay(alignment: .topTrailing) { bar }
    }

    private func row(_ index: Int, _ code: String) -> some View {
        let isSelected = selected == code
        return HStack(spacing: DowlioDesign.Spacing.sm) {
            Text(verbatim: "\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .frame(minWidth: 20, alignment: .trailing)
            Text(name(code))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DowlioDesign.Spacing.sm)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.leading, Self.barInset)
        .padding(.trailing, Self.barWidth + Self.barInset * 2)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { selected = code })
        .onDrag {
            dragging = code
            return NSItemProvider(object: code as NSString)
        }
        .onDrop(of: [.text], delegate: Reorder(target: code, languages: $languages, dragging: $dragging, changed: changed))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selected = code }
        .accessibilityAction(named: "Move Up") { move(code, by: -1) }
        .accessibilityAction(named: "Move Down") { move(code, by: 1) }
    }

    @ViewBuilder private var bar: some View {
        if contentHeight > height + 1 {
            let track = height - Self.barInset * 2
            let thumb = max(20, track * height / contentHeight)
            let progress = min(max(scrolled / (contentHeight - height), 0), 1)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.primary.opacity(0.35))
                    .frame(height: thumb)
                    .offset(y: (track - thumb) * progress)
            }
            .frame(width: Self.barWidth, height: track)
            .padding([.top, .trailing], Self.barInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func move(_ code: String, by step: Int) {
        guard let from = languages.firstIndex(of: code) else { return }
        let to = from + step
        guard languages.indices.contains(to) else { return }
        languages.swapAt(from, to)
        changed()
    }

    private struct Reorder: DropDelegate {
        let target: String
        @Binding var languages: [String]
        @Binding var dragging: String?
        let changed: () -> Void

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging != target,
                  let from = languages.firstIndex(of: dragging), let to = languages.firstIndex(of: target) else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                languages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            changed()
            return true
        }
    }
}
