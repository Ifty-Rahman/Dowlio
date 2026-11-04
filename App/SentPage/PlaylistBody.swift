import DowlioLibrary
import DowlioMedia
import SwiftUI

struct PlaylistBody: View {
    let media: SentPageModel

    var body: some View {
        if let playlist = media.draft.playlist {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
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
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Picker("Resolution", selection: choice) {
                        Text("Best available").tag(Choice.video(.best))
                        ForEach(VideoQuality.caps, id: \.self) { height in
                            Text(Self.name(of: height)).tag(Choice.video(.upTo(height)))
                        }
                        Divider()
                        Text("Audio only").tag(Choice.audio)
                    }
                    .fixedSize()
                    if let line = media.draft.playlistLine {
                        Text(line).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let note = media.draft.playlistResolutionNote {
                        Text(note).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                    if let note = media.draft.playlistNote {
                        Text(note).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        ForEach(playlist.entries) { entry in
                            PlaylistEntryRow(media: media, entry: entry)
                        }
                    }
                    .font(DowlioDesign.TypeRole.detail)
                }
                .frame(height: min(CGFloat(playlist.entries.count) * Self.rowHeight, 260))
            }
        }
    }

    private static let rowHeight: CGFloat = 31

    private static func name(of height: Int) -> String {
        switch height {
        case 2160: "2160p (4K)"
        case 1440: "1440p (2K)"
        default: "\(height)p"
        }
    }

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
        Toggle(isOn: Binding(get: { media.draft.isIncluded(entry) }, set: { media.include(entry, $0) })) {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                Text(verbatim: "\(entry.position)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                EntryThumbnail(url: entry.isAvailable ? entry.thumbnail : nil)
                    .frame(width: 48, height: 27)
                Text(entry.title).lineLimit(1).truncationMode(.tail)
                Spacer()
                if let duration = entry.duration {
                    Text(MediaText.duration(duration)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
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
