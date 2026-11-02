import SwiftUI
import DowlioLibrary

struct BlockedBody: View {
    let media: SentPageModel

    var body: some View {
        VStack(spacing: DowlioDesign.Spacing.sm) {
            Image(systemName: "hand.raised")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Blocked").font(DowlioDesign.TypeRole.heading)
            ForEach(media.draft.blocked, id: \.self) { line in
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
