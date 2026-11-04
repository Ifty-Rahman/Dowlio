import DowlioLibrary
import DowlioMedia
import SwiftUI

struct PlaylistBody: View {
    let media: SentPageModel

    var body: some View {
        if let playlist = media.draft.playlist {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
                Text(playlist.title).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                HStack {
                    Picker("Quality", selection: choice) {
                        Text("Best available").tag(Choice.video(.best))
                        ForEach(VideoQuality.caps, id: \.self) { cap in
                            Text(verbatim: "Up to \(cap)p").tag(Choice.video(.upTo(cap)))
                        }
                        Divider()
                        Text("Audio only").tag(Choice.audio)
                    }
                    .fixedSize()
                    Spacer()
                    if let line = media.draft.playlistLine {
                        Text(line).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                    }
                }
                if let note = media.draft.playlistNote {
                    Text(note).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                        ForEach(playlist.entries) { entry in
                            Toggle(isOn: Binding(get: { media.draft.isIncluded(entry) }, set: { media.include(entry, $0) })) {
                                HStack {
                                    Text(verbatim: "\(entry.position).").monospacedDigit().foregroundStyle(.secondary)
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
                    .font(DowlioDesign.TypeRole.detail)
                }
                .frame(maxHeight: 240)
            }
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
