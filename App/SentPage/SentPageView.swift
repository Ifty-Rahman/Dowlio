import DowlioCore
import DowlioLibrary
import DowlioMedia
import SwiftUI

struct SentPageView: View {
    let model: AppModel
    let sentPage: SentPageModel
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            switch sentPage.draft.phase {
            case .looking:
                looking
            case .oneVideo(let candidate):
                oneVideo(candidate)
            case .several(let candidates):
                several(candidates)
            case .nothingFound:
                nothingFound
            case .started(let id):
                started(id)
            }
        }
        .onHover { isHovering = $0 }
    }

    private var looking: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(sentPage.draft.host).font(DowlioDesign.TypeRole.heading).lineLimit(1)
            }
            Text("Looking at the page").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func oneVideo(_ candidate: Candidate) -> some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            if sentPage.draft.canGoBack {
                Button("Back", systemImage: "chevron.left") { sentPage.backToList() }
                    .buttonStyle(.borderless)
            }
            CandidateHeader(candidate: candidate, host: sentPage.draft.host)
            VStack(spacing: DowlioDesign.Spacing.xs) {
                ForEach(Array(candidate.versions.enumerated()), id: \.offset) { _, version in
                    VersionRow(version: version, isChosen: version == sentPage.draft.chosenVersion) { sentPage.pick(version) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("Download") { download() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sentPage.draft.chosenVersion == nil)
            }
        }
    }

    private func several(_ candidates: [Candidate]) -> some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text("\(candidates.count) videos on \(sentPage.draft.host)").font(DowlioDesign.TypeRole.heading)
            if candidates.count > Self.rowsBeforeScrolling {
                ScrollView { candidateRows(candidates) }
                    .frame(height: 260)
            } else {
                candidateRows(candidates)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private static let rowsBeforeScrolling = 5

    private func candidateRows(_ candidates: [Candidate]) -> some View {
        VStack(spacing: DowlioDesign.Spacing.xs) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                Button { sentPage.choose(candidate) } label: {
                    HStack(spacing: DowlioDesign.Spacing.sm) {
                        Text(candidate.label).lineLimit(1)
                        Spacer(minLength: DowlioDesign.Spacing.sm)
                        Text(candidate.versions.first.map(SentPageDraft.summary(of:)) ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(DowlioDesign.TypeRole.detail)
                    .padding(DowlioDesign.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text(sentPage.draft.host).font(DowlioDesign.TypeRole.heading).lineLimit(1)
            Text("No video or audio found on this page").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func started(_ id: DownloadID) -> some View {
        let row = model.row(id)
        return VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text(row?.fileName ?? "Starting…").font(DowlioDesign.TypeRole.heading).lineLimit(1).truncationMode(.middle)
            if let row, row.state == .completed {
                HStack {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") {
                        model.showInFinder(row)
                        close()
                    }
                }
                .font(DowlioDesign.TypeRole.detail)
            } else {
                ProgressView(value: row.flatMap(Self.fraction) ?? 0)
                Text(row?.detailLine ?? "Starting…").font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
        }
        .task(id: isHovering) {
            guard !isHovering else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, !isHovering { close() }
        }
    }

    private static func fraction(_ row: DownloadRow) -> Double? {
        guard let total = row.totalBytes, total > 0 else { return nil }
        return min(Double(row.receivedBytes) / Double(total), 1)
    }

    private func download() {
        guard let version = sentPage.draft.chosenVersion else { return }
        let download = sentPage.draft.download(version)
        Task {
            guard let id = await model.addSent(download) else { return }
            sentPage.started(id)
        }
    }
}

private struct VersionRow: View {
    let version: Version
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DowlioDesign.Spacing.sm) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                Text(SentPageDraft.summary(of: version))
                Spacer(minLength: 0)
            }
            .font(DowlioDesign.TypeRole.detail)
            .padding(DowlioDesign.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

private struct CandidateHeader: View {
    let candidate: Candidate
    let host: String

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.md) {
            AsyncImage(url: candidate.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "play.rectangle").font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                Text(candidate.label).font(DowlioDesign.TypeRole.heading).lineLimit(2)
                Text([host, candidate.duration.map(SentPageDraft.durationText)].compactMap { $0 }.joined(separator: " · "))
                    .font(DowlioDesign.TypeRole.detail)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
