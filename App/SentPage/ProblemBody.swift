import DowlioLibrary
import SwiftUI

struct ProblemBody: View {
    let media: SentPageModel

    var body: some View {
        if let problem = media.draft.problem {
            VStack(spacing: DowlioDesign.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(problem.sentence)
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = problem.action {
                    Button(action.title) { perform(action) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DowlioDesign.Spacing.sm)
        }
    }

    private func perform(_ action: ProblemText.Action) {
        switch action {
        case .lookAgain: media.lookAgain()
        case .tryAgain: media.tryAgain()
        case .checkForUpdate: media.checkForToolUpdate()
        }
    }
}
