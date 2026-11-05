import DowlioLibrary
import DowlioMedia
import SwiftUI

struct PlaylistBody: View {
    let media: SentPageModel

    var body: some View {
        if let playlist = media.draft.playlist {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.lg) {
                header(playlist)
                controls
                videos(playlist)
            }
        }
    }

    private func header(_ playlist: PlaylistListing) -> some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            PlaylistCover(url: playlist.thumbnail ?? playlist.entries.lazy.compactMap(\.thumbnail).first, count: playlist.available.count)
                .frame(width: playlist.isMusic ? 63 : 112, height: 63)
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                Text(playlist.title).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                if let byline = media.draft.playlistByline {
                    Text(byline).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            HStack(spacing: DowlioDesign.Spacing.xs) {
                Text("Resolution").font(DowlioDesign.TypeRole.detail.weight(.semibold))
                if media.draft.isCheckingResolutions {
                    ProgressView().controlSize(.mini)
                    Text("Checking").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                }
            }
            ChipFlow(spacing: DowlioDesign.Spacing.xs) {
                chip("Best", .video(.best))
                ForEach(media.draft.playlistHeights, id: \.self) { height in
                    chip(media.draft.resolutionName(of: height), .video(.upTo(height)))
                }
                chip("Audio only", .audio)
            }
            ForEach([media.draft.playlistResolutionNote, media.draft.playlistNote].compactMap { $0 }, id: \.self) { note in
                Text(note).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ title: String, _ value: Choice) -> some View {
        let isChosen = choice.wrappedValue == value
        return Button { choice.wrappedValue = value } label: {
            Text(title)
                .font(DowlioDesign.TypeRole.detail.weight(isChosen ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, DowlioDesign.Spacing.sm)
                .padding(.vertical, DowlioDesign.Spacing.xs)
                .foregroundStyle(isChosen ? Color.white : Color.primary)
                .background(isChosen ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func videos(_ playlist: PlaylistListing) -> some View {
        let allIncluded = media.draft.includedEntries.count == playlist.available.count
        return VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            HStack {
                if let line = media.draft.playlistLine {
                    Text(line).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button(allIncluded ? "Select None" : "Select All") {
                    for entry in playlist.available { media.include(entry, !allIncluded) }
                }
                .buttonStyle(.link)
            }
            .font(DowlioDesign.TypeRole.detail)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(playlist.entries) { entry in
                        PlaylistEntryRow(media: media, entry: entry)
                    }
                }
                .padding(.vertical, DowlioDesign.Spacing.xs)
                .padding(.leading, DowlioDesign.Spacing.sm)
                .padding(.trailing, DowlioDesign.Spacing.md + DowlioDesign.Spacing.xs)
                .font(DowlioDesign.TypeRole.detail)
            }
            .frame(height: min(CGFloat(playlist.entries.count) * (Self.rowHeight + Self.rowSpacing) + DowlioDesign.Spacing.sm, 280))
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .overlay(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    static let rowHeight: CGFloat = 36
    private static let rowSpacing: CGFloat = 2

    private enum Choice: Hashable {
        case video(VideoQuality)
        case audio
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { media.draft.playlistShowing == .audio ? .audio : .video(media.draft.playlistQuality) },
            set: { picked in
                switch picked {
                case .audio: media.choosePlaylist(.audio)
                case .video(let quality): media.choosePlaylist(.video, quality: quality)
                }
            }
        )
    }
}

private struct PlaylistEntryRow: View {
    let media: SentPageModel
    let entry: PlaylistListing.Entry

    var body: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            Toggle(entry.title, isOn: Binding(get: { media.draft.isIncluded(entry) }, set: { media.include(entry, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(verbatim: "\(entry.position)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            EntryThumbnail(url: entry.isAvailable ? entry.thumbnail : nil)
                .frame(width: 48, height: 27)
            Text(entry.title)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = entry.duration {
                Text(MediaText.duration(duration)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        }
        .frame(height: PlaylistBody.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if entry.isAvailable { media.include(entry, !media.draft.isIncluded(entry)) } }
        .disabled(!entry.isAvailable)
        .opacity(entry.isAvailable ? 1 : 0.45)
        .help(entry.isAvailable ? entry.title : "This video is private or deleted, so Dowlio leaves it out.")
    }
}

private struct EntryThumbnail: View {
    let url: URL?

    var body: some View {
        Color.secondary.opacity(0.15)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

private struct PlaylistCover: View {
    let url: URL?
    let count: Int

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
            .overlay(alignment: .bottomTrailing) {
                Label("\(count)", systemImage: "list.bullet")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .accessibilityHidden(true)
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for row in rows {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowWidth = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            width = max(width, rowWidth)
            height += sizes.map(\.height).max() ?? 0
        }
        height += spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let item = subviews[index].sizeThatFits(.unspecified).width
            if !rows[rows.count - 1].isEmpty, used + spacing + item > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + item
            rows[rows.count - 1].append(index)
        }
        return rows
    }
}
