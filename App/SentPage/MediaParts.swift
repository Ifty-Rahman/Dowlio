import DowlioCore
import DowlioLibrary
import DowlioMedia
import SwiftUI

struct MediaHeader: View {
    let media: SentPageModel
    var subtitle: String?
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            if media.draft.phase == .found, let candidate = media.draft.selectedCandidate {
                VideoThumbnail(url: candidate.thumbnail, duration: candidate.duration)
                    .frame(width: 112, height: 63)
            } else {
                InitialTile(host: media.draft.host)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                Text(title).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                Text(subtitle ?? media.draft.sourceLine)
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var title: String {
        if media.draft.phase == .found, let label = media.draft.selectedCandidate?.label, !label.isEmpty { return label }
        return media.draft.page.title ?? media.draft.host
    }
}

struct VideoThumbnail: View {
    let url: URL?
    let duration: Double?
    var compact = false

    var body: some View {
        Color(nsColor: .darkGray)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: compact ? 11 : 14))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(MediaText.duration(duration))
                        .font(.system(size: compact ? 9 : 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(compact ? 3 : 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : DowlioDesign.Radius.nested))
            .accessibilityHidden(true)
    }
}

struct InitialTile: View {
    let host: String

    var body: some View {
        let letter = host.first.map { String($0).uppercased() } ?? "?"
        let hues: [Color] = [.orange, .teal, .indigo, .pink, .green, .purple, .blue, .brown]
        let hue = hues[abs(host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % hues.count]
        Text(letter)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hue.gradient, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .accessibilityHidden(true)
    }
}

struct MediaChoices: View {
    let media: SentPageModel
    @Binding var makesDefaultQuality: Bool
    var boxed = false

    var body: some View {
        if let line = media.draft.restrictionLine {
            RestrictionNote(line: line, isLive: media.draft.selectedCandidate?.restriction == .live)
        } else {
            choices
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            if media.draft.hasVideoAndAudio {
                Picker("Show", selection: Binding(get: { media.draft.showing }, set: { media.show($0) })) {
                    Text("Video").tag(SentPageDraft.Showing.video)
                    Text("Audio only").tag(SentPageDraft.Showing.audio)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            rows
            if let height = media.draft.chosenVersion.flatMap({ MediaText.isAudio($0) ? nil : $0.height }) {
                Toggle(isOn: $makesDefaultQuality) { Text(verbatim: "Make \(height)p my default quality") }
                    .toggleStyle(.checkbox)
                    .font(DowlioDesign.TypeRole.detail)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        let list = VersionRows(media: media)
        if boxed {
            list
                .padding(DowlioDesign.Spacing.xs)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.container))
                .overlay(RoundedRectangle(cornerRadius: DowlioDesign.Radius.container).strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            list
        }
    }
}

struct VersionRows: View {
    let media: SentPageModel
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let visibleRows = 6

    var body: some View {
        let versions = versions
        Group {
            if versions.count > Self.visibleRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        list(versions)
                    }
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + CGFloat(Self.visibleRows - 1) * Self.spacing)
                    .onAppear { reveal(in: versions, with: proxy, animated: false) }
                    .onChange(of: media.draft.chosenVersion) { reveal(in: versions, with: proxy, animated: true) }
                }
            } else {
                list(versions)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            media.moveChoice(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            media.moveChoice(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Versions")
    }

    private func list(_ versions: [Version]) -> some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                VersionRow(version: version, isChosen: version == media.draft.chosenVersion) {
                    media.pick(version)
                    focused = true
                }
                .frame(height: Self.rowHeight)
                .id(index)
            }
        }
    }

    private func reveal(in versions: [Version], with proxy: ScrollViewProxy, animated: Bool) {
        guard let chosen = media.draft.chosenVersion, let index = versions.firstIndex(of: chosen) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(index) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private var versions: [Version] {
        media.draft.hasVideoAndAudio ? media.draft.versions(showing: media.draft.showing) : media.draft.selectedCandidate?.versions ?? []
    }
}

private struct VersionRow: View {
    let version: Version
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DowlioDesign.Spacing.md) {
                Image(systemName: isChosen ? "smallcircle.filled.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                Text(MediaText.title(of: version))
                    .font(DowlioDesign.TypeRole.heading)
                    .frame(width: 58, alignment: .leading)
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    Text(MediaText.detail(of: version))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !MediaText.playsInQuickTime(version) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.85))
                            .help("May not play in QuickTime")
                            .accessibilityLabel("May not play in QuickTime")
                    }
                }
                .font(DowlioDesign.TypeRole.detail)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                Text(MediaText.size(of: version) ?? "")
                    .font(DowlioDesign.TypeRole.detailMetric)
                    .fixedSize()
            }
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isChosen ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

struct SkeletonRows: View {
    var count = 3

    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 30)
            }
        }
        .accessibilityHidden(true)
    }
}

struct VideoStrip: View {
    let media: SentPageModel
    @State private var first = 0
    @State private var width: CGFloat = 0

    private static let shown = 3
    private static let gap: CGFloat = DowlioDesign.Spacing.sm
    private static let ring: CGFloat = 3

    var body: some View {
        let count = media.draft.candidates.count
        let last = max(count - Self.shown, 0)
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            HStack(spacing: DowlioDesign.Spacing.xs) {
                Text(summary(count))
                    .font(DowlioDesign.TypeRole.detail.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if count > Self.shown {
                    StripArrow(systemImage: "chevron.left", label: "Previous videos", isEnabled: first > 0) { move(by: -1, last: last) }
                    StripArrow(systemImage: "chevron.right", label: "Next videos", isEnabled: first < last) { move(by: 1, last: last) }
                }
            }
            HStack(spacing: Self.gap) {
                ForEach(Array(media.draft.candidates.enumerated()), id: \.offset) { index, candidate in
                    let visible = index >= first && index < first + Self.shown
                    VideoCard(
                            candidate: candidate,
                            number: index + 1,
                            isShown: index == media.draft.selected,
                            isIncluded: media.draft.isIncluded(index),
                            ring: Self.ring,
                            show: { media.select(index) },
                        toggle: { media.include(index, !media.draft.isIncluded(index)) }
                    )
                    .frame(width: cardWidth)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                }
            }
            .offset(x: -CGFloat(first) * (cardWidth + Self.gap))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: cardHeight)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .onChange(of: media.draft.selected) { _, selected in reveal(selected, last: last) }
        .onChange(of: count) { first = min(first, last) }
    }

    private var cardWidth: CGFloat {
        max((width - Self.gap * CGFloat(Self.shown - 1)) / CGFloat(Self.shown), 0)
    }

    private var cardHeight: CGFloat {
        max(cardWidth - Self.ring * 2, 0) * 9 / 16 + Self.ring * 2
    }

    private func summary(_ count: Int) -> String {
        let chosen = (0..<count).filter { media.draft.isIncluded($0) }.count
        return chosen == count ? "\(count) videos on this page" : "\(chosen) of \(count) videos chosen"
    }

    private func move(by step: Int, last: Int) {
        withAnimation(.snappy(duration: 0.28)) { first = min(max(first + step, 0), last) }
    }

    private func reveal(_ index: Int, last: Int) {
        guard index < first || index >= first + Self.shown else { return }
        withAnimation(.snappy(duration: 0.28)) { first = min(max(index < first ? index : index - Self.shown + 1, 0), last) }
    }
}

private struct StripArrow: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(isHovered && isEnabled ? 0.25 : 0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct VideoCard: View {
    let candidate: Candidate
    let number: Int
    let isShown: Bool
    let isIncluded: Bool
    let ring: CGFloat
    let show: () -> Void
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: show) {
                VideoThumbnail(url: candidate.thumbnail, duration: candidate.duration, compact: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .opacity(isIncluded ? 1 : 0.45)
                    .padding(ring)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6 + ring)
                            .strokeBorder(isShown ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.35 : 0), lineWidth: 2)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomLeading) {
                if let restriction = candidate.restriction {
                    RestrictionBadge(restriction: restriction).padding(ring + 4)
                }
            }
            .help(candidate.label)
            .accessibilityLabel("Video \(number): \(candidate.label)")
            .accessibilityAddTraits(isShown ? .isSelected : [])

            Button(action: toggle) {
                SelectionMark(isOn: isIncluded)
                    .padding(ring + 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isIncluded ? "Leave this video out" : "Download this video too")
            .accessibilityLabel("Download video \(number)")
            .accessibilityValue(isIncluded ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isIncluded)
        .animation(.easeOut(duration: 0.15), value: isShown)
    }
}

private struct SelectionMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.accentColor : Color.black.opacity(0.35))
            Circle()
                .strokeBorder(.white, lineWidth: isOn ? 0 : 1.5)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}

private struct RestrictionBadge: View {
    let restriction: Candidate.Restriction

    var body: some View {
        Group {
            if restriction == .live {
                Circle().fill(.red).frame(width: 7, height: 7)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .background(.black.opacity(0.55), in: Circle())
        .accessibilityLabel(restriction == .live ? "Live stream" : "Protected")
    }
}

struct RestrictionNote: View {
    let line: String
    let isLive: Bool

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            if isLive {
                Circle().fill(.red).frame(width: 8, height: 8)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            Text(line).font(DowlioDesign.TypeRole.detail)
        }
        .padding(.vertical, DowlioDesign.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct LookingLine: View {
    let media: SentPageModel

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(media.draft.lookingLine)
            if media.draft.phase == .playing {
                Spacer(minLength: DowlioDesign.Spacing.sm)
                Button("Cancel") { media.cancelPlaying() }
                    .controlSize(.small)
            }
        }
        .font(DowlioDesign.TypeRole.detail)
        .foregroundStyle(.secondary)
    }
}

struct NothingFoundBody: View {
    let media: SentPageModel

    var body: some View {
        let text = media.draft.nothingFound
        VStack(spacing: DowlioDesign.Spacing.sm) {
            Image(systemName: "video.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(text.title).font(DowlioDesign.TypeRole.heading)
            Group {
                Text(text.explanation)
                if let note = text.note { Text(note) }
            }
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button(text.action) { media.lookAgain() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DowlioDesign.Spacing.sm)
    }
}

struct NeedsSignInBody: View {
    let media: SentPageModel

    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Needs sign-in").font(DowlioDesign.TypeRole.heading)
            ForEach(media.draft.signIn, id: \.self) { line in
                Text(line)
            }
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DowlioDesign.Spacing.sm)
    }
}
