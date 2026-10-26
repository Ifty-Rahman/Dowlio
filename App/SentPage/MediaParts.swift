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

    var body: some View {
        ZStack {
            Color(nsColor: .darkGray)
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                EmptyView()
            }
            Image(systemName: "play.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration {
                Text(MediaText.duration(duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
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

struct VersionRows: View {
    let media: SentPageModel
    let showing: SentPageDraft.Showing

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(versions.enumerated()), id: \.offset) { _, version in
                VersionRow(version: version, isChosen: version == media.draft.chosenVersion) { media.pick(version) }
            }
        }
    }

    private var versions: [Version] {
        media.draft.hasVideoAndAudio ? media.draft.versions(showing: showing) : media.draft.selectedCandidate?.versions ?? []
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
                    .frame(width: 64, alignment: .leading)
                Spacer(minLength: DowlioDesign.Spacing.sm)
                Text(MediaText.size(of: version) ?? "")
                    .font(DowlioDesign.TypeRole.detailMetric)
            }
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text("\(media.draft.candidates.count) videos on this page")
                .font(DowlioDesign.TypeRole.detail.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DowlioDesign.Spacing.sm) {
                    ForEach(Array(media.draft.candidates.enumerated()), id: \.offset) { index, candidate in
                        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                            Button { media.select(index) } label: {
                                VideoThumbnail(url: candidate.thumbnail, duration: candidate.duration)
                                    .frame(width: 84, height: 50)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested)
                                            .strokeBorder(Color.accentColor, lineWidth: index == media.draft.selected ? 2.5 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(candidate.label)
                            .accessibilityLabel("Video \(index + 1): \(candidate.label)")
                            Toggle("Include", isOn: Binding(
                                get: { media.draft.isIncluded(index) },
                                set: { media.include(index, $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(DowlioDesign.TypeRole.detail)
                        }
                    }
                }
            }
        }
    }
}

struct NothingFoundBody: View {
    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            Image(systemName: "video.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No video or audio on this page").font(DowlioDesign.TypeRole.heading)
            Text("Dowlio couldn't find anything to download here. You can open Dowlio and paste a different link.")
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DowlioDesign.Spacing.sm)
    }
}
