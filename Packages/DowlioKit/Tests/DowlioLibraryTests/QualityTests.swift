import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

@MainActor
struct QualityTests {
    private static func video(_ height: Int?, _ codecs: String?, _ ext: String = "mp4") -> Version {
        Version(source: .file(URL(string: "https://cdn.example.com/\(height ?? 0)-\(codecs ?? "x").\(ext)")!), contentType: "video/\(ext)", height: height, codecs: codecs)
    }
    private let h264_1080 = video(1080, "H.264 + AAC")
    private let h264_720 = video(720, "H.264 + AAC")
    private let vp9_1080 = video(1080, "VP9 + AAC")
    private let av1_2160 = video(2160, "AV1")
    private let h264_360 = video(360, "H.264 + AAC")
    private let audio = Version(source: .file(URL(string: "https://cdn.example.com/a.m4a")!), contentType: "audio/mp4", totalBytes: 900)

    @Test func bestAvailableTakesTheHighestH264WhenH264IsPreferred() {
        let preference = QualityPreference(quality: .best, prefersH264: true)

        #expect(preference.pick(from: [vp9_1080, h264_720, av1_2160], showing: .video) == h264_720)
    }

    @Test func bestAvailableTakesTheHighestOfAnyKindWhenH264IsntPreferred() {
        let preference = QualityPreference(quality: .best, prefersH264: false)

        #expect(preference.pick(from: [h264_720, av1_2160, vp9_1080], showing: .video) == av1_2160)
    }

    @Test func aCapTakesTheHighestAtOrBelowIt() {
        let preference = QualityPreference(quality: .upTo(720), prefersH264: true)

        #expect(preference.pick(from: [h264_1080, h264_720, h264_360], showing: .video) == h264_720)
    }

    @Test func aCapBelowEveryVersionTakesTheLowest() {
        let preference = QualityPreference(quality: .upTo(360), prefersH264: true)

        #expect(preference.pick(from: [h264_1080, h264_720], showing: .video) == h264_720)
    }

    @Test func versionsWithoutAKnownHeightComeAfterTheOnesWithOne() {
        let unknown = Self.video(nil, nil)

        #expect(QualityPreference().pick(from: [unknown, h264_720], showing: .video) == h264_720)
        #expect(QualityPreference().pick(from: [unknown], showing: .video) == unknown)
    }

    @Test func audioOnlyTakesTheAudio() {
        #expect(QualityPreference().pick(from: [h264_720, audio], showing: .audio) == audio)
    }

    @Test func aSentPageStartsOnThePreferredVersionAndAVideoWithoutAudioKeepsIt() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.example.com/watch")!), preference: QualityPreference(quality: .upTo(720), prefersH264: true))
        _ = draft.update(.found([Candidate(label: "Clip", versions: [h264_1080, h264_720, h264_360])]))

        #expect(draft.chosenVersion == h264_720)
        draft.show(.audio)
        #expect(draft.chosenVersion == h264_720)
    }

    @Test func aVersionRowReadsResolutionTypeCodecsAndSize() {
        var estimated = h264_1080
        estimated.totalBytes = 38_200_000
        estimated.isEstimatedSize = true

        #expect(MediaText.title(of: h264_1080) == "1080p")
        #expect(MediaText.detail(of: h264_1080) == "MP4 · H.264 + AAC")
        #expect(MediaText.size(of: estimated) == "~38.2 MB")
        #expect(MediaText.title(of: audio) == "Audio")
    }

    @Test func aVideoIsNamedAfterItsLabelWithTheResolutionOnlyWhenTheNameIsTaken() {
        #expect(MediaNaming.fileName(label: "Holiday clip", version: h264_720) { _ in false } == "Holiday clip.mp4")
        #expect(MediaNaming.fileName(label: "Holiday clip", version: h264_720) { $0 == "Holiday clip.mp4" } == "Holiday clip (720p).mp4")
        #expect(MediaNaming.fileName(label: "Week 1: part/2", version: h264_720) { _ in false } == "Week 1- part-2.mp4")
        #expect(MediaNaming.fileName(label: " ", version: Self.video(nil, nil)) { _ in false } == "0-x.mp4")
    }

    @Test func theArrowKeysMoveTheChoiceThroughTheRowsOnShow() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.example.com/watch")!))
        _ = draft.update(.found([Candidate(label: "Clip", versions: [h264_1080, h264_720, h264_360, audio])]))

        #expect(draft.chosenVersion == h264_1080)
        draft.moveChoice(by: 1)
        #expect(draft.chosenVersion == h264_720)
        draft.moveChoice(by: 5)
        #expect(draft.chosenVersion == h264_360)
        draft.moveChoice(by: -9)
        #expect(draft.chosenVersion == h264_1080)
    }

    @Test func downloadSettingsCarryTheQualityPreference() {
        var settings = DownloadSettings(folder: URL(filePath: "/tmp"))
        #expect(settings.qualityPreference == QualityPreference(quality: .best, prefersH264: true))
        settings.videoQualityCap = 720
        settings.prefersH264 = false
        #expect(settings.qualityPreference == QualityPreference(quality: .upTo(720), prefersH264: false))
    }

    @Test func preferringH264TakesAnMP4OverAnotherContainer() {
        let webm = Self.video(1080, "H.264", "webm")
        let mp4 = Self.video(720, "H.264")

        #expect(QualityPreference(prefersH264: true).pick(from: [webm, mp4], showing: .video) == mp4)
    }

    @Test func switchingToAudioAndBackPicksTheBestOfEachKind() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.example.com/watch")!))
        _ = draft.update(.found([Candidate(label: "Talk", versions: [h264_720, audio, h264_1080])]))

        #expect(draft.chosenVersion == h264_1080)
        draft.show(.audio)
        #expect(draft.chosenVersion == audio)
        draft.show(.video)
        #expect(draft.chosenVersion == h264_1080)
    }

    @Test func theResolutionIsLeftOffWhenTheNameConflictSettingIsntKeepBoth() {
        #expect(MediaNaming.fileName(label: "Clip", version: h264_720, addsResolution: false) { _ in true } == "Clip.mp4")
    }

    @Test(arguments: [
        ("/vid/avc1/720x1280/a.mp4", 720, "H.264"),
        ("/dload/240/abc-240p-av1.mp4", 240, "AV1"),
        ("/videos/1080p.webm", 1080, nil),
        ("/advanced/navigation1080.mp4", nil, nil),
        ("/path/nav1/x.mp4", nil, nil),
        ("/clip_vp9_480p.webm", 480, "VP9"),
    ] as [(String, Int?, String?)])
    func aResolutionAndCodecAreReadFromAnAddressButNotFromInsideWords(path: String, height: Int?, codecs: String?) {
        #expect(MediaFile.height(in: path) == height)
        #expect(MediaFile.codecs(in: path) == codecs)
    }
}
