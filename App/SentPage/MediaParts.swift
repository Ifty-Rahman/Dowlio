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
                if media.draft.phase == .found, media.draft.selectedCandidate?.isOnScreen == true { OnScreenTag() }
                Text(placeLine ?? subtitle ?? media.draft.sourceLine)
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

    private var placeLine: String? {
        media.draft.phase == .found && media.draft.selectedCandidate?.isOther == true ? "Other videos on this page" : nil
    }

    private var title: String {
        if media.draft.phase == .found, let label = media.draft.selectedCandidate?.label, !label.isEmpty { return label }
        return media.draft.page.title ?? media.draft.host
    }
}

struct OnScreenTag: View {
    var body: some View {
        Label("On screen", systemImage: "eye.fill")
            .font(DowlioDesign.TypeRole.detail.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.vertical, DowlioDesign.Spacing.xs / 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
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
                .allowsHitTesting(false)
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
            .contentShape(RoundedRectangle(cornerRadius: compact ? 6 : DowlioDesign.Radius.nested))
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
    var boxed = false

    var body: some View {
        if let line = media.draft.restrictionLine {
            RestrictionNote(line: line, isLive: media.draft.selectedCandidate?.restriction == .live)
        } else if media.draft.selectedCandidate?.needsProbe == true {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
                SkeletonRows()
                HStack(spacing: DowlioDesign.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Looking at this video")
                }
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
            }
        } else if media.draft.selectedCandidate?.versions.isEmpty == true {
            Text("No video found for this one")
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
        } else {
            choices
            if let whole = media.draft.wholePlaylistLine {
                Button(whole, systemImage: "list.bullet") { media.showWholePlaylist() }
                    .buttonStyle(.link)
                    .font(DowlioDesign.TypeRole.detail)
            }
            if let subtitles = media.draft.subtitlesLine {
                Label(subtitles, systemImage: "captions.bubble")
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
            if media.draft.isCheckingForMore { CheckingForMoreLine(media: media) }
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
            if media.draft.isSelecting || media.draft.selectedCandidate.map({ $0.versions.count > 1 }) == true { SelectionBar(media: media) }
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

struct SelectionBar: View {
    let media: SentPageModel

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            Toggle(isOn: Binding(get: { media.draft.isSelecting }, set: { media.setSelecting($0) })) {
                Label("Select", systemImage: "checklist")
            }
            .toggleStyle(.button)
            .help(media.draft.isSelecting ? "Go back to downloading one version" : "Pick several versions to download")
            if media.draft.isSelecting {
                ViewThatFits(in: .horizontal) {
                    Text(media.draft.selectionLine)
                    Text(media.draft.selectionLine(.short))
                    Text(media.draft.selectionLine(.total)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(media.draft.selectionLine)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                let all = media.draft.selectsAllShown
                Button(all ? "Deselect All" : "Select All") { media.selectAllShown(!all) }
                    .help(scopeHelp(all))
            }
        }
        .controlSize(.small)
        .font(DowlioDesign.TypeRole.detail)
    }

    private func scopeHelp(_ all: Bool) -> String {
        let kind = media.draft.hasVideoAndAudio ? (media.draft.showing == .audio ? " audio" : " video") : ""
        return all ? "Untick every\(kind) version" : "Tick every\(kind) version"
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
        .onKeyPress(.space) {
            guard media.draft.isSelecting else { return .ignored }
            media.toggleChosen()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Versions")
    }

    private func list(_ versions: [Version]) -> some View {
        let labelWidth: CGFloat = versions.contains(where: \.isHighFrameRate) ? 78 : 58
        return VStack(spacing: Self.spacing) {
            ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                VersionRow(
                    version: version, isChosen: version == media.draft.chosenVersion, selecting: selecting(version),
                    showsCursor: focused, labelWidth: labelWidth
                ) {
                    if media.draft.isSelecting { media.toggle(version) } else { media.pick(version) }
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

    private var versions: [Version] { media.draft.shownVersions }

    private func selecting(_ version: Version) -> VersionRow.Selecting? {
        media.draft.isSelecting ? VersionRow.Selecting(isTicked: media.draft.isTicked(version)) : nil
    }
}

private struct VersionRow: View {
    struct Selecting {
        var isTicked: Bool
    }

    let version: Version
    let isChosen: Bool
    let selecting: Selecting?
    let showsCursor: Bool
    let labelWidth: CGFloat
    let choose: () -> Void

    private var isMarked: Bool { selecting?.isTicked ?? isChosen }

    private var symbol: String {
        if let selecting { return selecting.isTicked ? "checkmark.square.fill" : "square" }
        return isChosen ? "smallcircle.filled.circle.fill" : "circle"
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DowlioDesign.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isMarked ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(MediaText.title(of: version))
                    .font(DowlioDesign.TypeRole.heading)
                    .frame(width: labelWidth, alignment: .leading)
                Text(MediaText.detail(of: version))
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                Text(MediaText.size(of: version) ?? "")
                    .font(DowlioDesign.TypeRole.detailMetric)
                    .fixedSize()
            }
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isMarked ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .overlay {
                if selecting != nil, isChosen, showsCursor {
                    RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested).strokeBorder(Color.accentColor.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isMarked ? .isSelected : [])
        .accessibilityHint(selecting == nil ? "" : "Ticks or unticks this version")
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

struct CheckingForMoreLine: View {
    let media: SentPageModel

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(media.draft.checkingLine)
            Spacer(minLength: DowlioDesign.Spacing.sm)
            Button("Cancel") { media.stopChecking() }
                .controlSize(.small)
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
            Text(text.explanation)
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(text.action) { media.lookAgain() }
                if let ytdlp = text.ytdlpAction {
                    Button(ytdlp) { media.tryWithYTDLP() }
                        .help("yt-dlp, a free open-source tool, can read many sites Dowlio can't. Dowlio asks before downloading it.")
                }
            }
            OpenInWindowButton(media: media)
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
            OpenInWindowButton(media: media)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DowlioDesign.Spacing.sm)
    }
}
