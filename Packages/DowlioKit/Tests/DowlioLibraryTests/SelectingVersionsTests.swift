import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct SelectingVersionsTests {
    private let page = SentPage(url: URL(string: "https://www.example.com/watch")!)
    private let p1080 = Version(source: .file(URL(string: "https://cdn.example.com/1080.mp4")!), contentType: "video/mp4", totalBytes: 3_000_000, height: 1080)
    private let p720 = Version(source: .file(URL(string: "https://cdn.example.com/720.mp4")!), contentType: "video/mp4", totalBytes: 2_000_000, height: 720)
    private let p360 = Version(source: .file(URL(string: "https://cdn.example.com/360.mp4")!), contentType: "video/mp4", totalBytes: 1_000_000, height: 360)
    private let m4a = Version(source: .file(URL(string: "https://cdn.example.com/a.m4a")!), contentType: "audio/mp4", totalBytes: 500_000)
    private let opus = Version(source: .file(URL(string: "https://cdn.example.com/a.opus")!), contentType: "audio/ogg", totalBytes: 400_000)
    private var talk: Candidate { Candidate(label: "Talk", versions: [p1080, p720, p360, m4a, opus]) }
    private var other: Candidate { Candidate(label: "Other", versions: [p720, p360]) }

    private func found(_ candidates: [Candidate]) -> SentPageDraft {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found(candidates))
        return draft
    }

    @Test func selectingStartsWithTheChosenVersionTicked() {
        var draft = found([talk])
        draft.pick(p720)

        draft.setSelecting(true)

        #expect(draft.isSelecting)
        #expect(draft.selectedVersions(of: 0) == [p720])
    }

    @Test func tickingRowsAddsAndRemovesVersionsInListOrder() {
        var draft = found([talk])
        draft.setSelecting(true)

        draft.toggle(p360)
        draft.toggle(m4a)
        #expect(draft.selectedVersions(of: 0) == [p1080, p360, m4a])

        draft.toggle(p1080)
        #expect(draft.selectedVersions(of: 0) == [p360, m4a])
    }

    @Test func rowsCantBeTickedWithoutSelecting() {
        var draft = found([talk])

        draft.toggle(p360)

        #expect(draft.selectedVersions(of: 0) == [p1080])
    }

    @Test func selectAllTicksOnlyTheVideoOrAudioOnShow() {
        var draft = found([talk])
        draft.setSelecting(true)

        draft.selectAllShown(true)
        #expect(draft.selectedVersions(of: 0) == [p1080, p720, p360])
        #expect(draft.selectsAllShown)

        draft.show(.audio)
        #expect(!draft.selectsAllShown)
        draft.selectAllShown(true)
        #expect(draft.selectedVersions(of: 0) == [p1080, p720, p360, m4a, opus])

        draft.selectAllShown(false)
        #expect(draft.selectedVersions(of: 0) == [p1080, p720, p360])
        draft.show(.video)
        #expect(draft.selectsAllShown)
    }

    @Test func theSelectionLineCountsVideoAndAudioApartWithTheirSize() {
        var draft = found([talk])
        draft.setSelecting(true)
        draft.toggle(p720)
        draft.toggle(m4a)

        #expect(draft.selectionLine == "2 video, 1 audio selected · 5.50 MB")
        #expect(draft.selectionLine(.short) == "2 video, 1 audio · 5.50 MB")
        #expect(draft.selectionLine(.total) == "3 · 5.50 MB")
        draft.toggle(p1080)
        draft.toggle(p720)
        #expect(draft.selectionLine == "1 audio selected · 500 KB")
        draft.selectAllShown(false)
        draft.show(.audio)
        draft.selectAllShown(false)
        #expect(draft.selectionLine == "Nothing selected")
    }

    @Test func aVideoWithOneKindCountsJustTheNumber() {
        var draft = found([other])
        draft.setSelecting(true)
        draft.selectAllShown(true)

        #expect(draft.selectionLine == "2 selected · 3.00 MB")
        #expect(draft.selectionLine(.short) == "2 · 3.00 MB")
    }

    @Test func anUnknownSizeLeavesTheTotalOut() {
        let unsized = Version(source: .file(URL(string: "https://cdn.example.com/x.mp4")!), height: 480)
        var draft = found([Candidate(label: "Clip", versions: [p720, unsized])])
        draft.setSelecting(true)
        draft.selectAllShown(true)

        #expect(draft.selectionLine == "2 selected")
    }

    @Test func everySelectedVersionOfAnIncludedVideoDownloads() {
        var draft = found([talk, other])
        draft.setSelecting(true)
        draft.toggle(m4a)
        draft.include(1, true)

        #expect(draft.downloads.map(\.version) == [p1080, m4a, p720])
    }

    @Test func tickingAVersionIncludesItsVideoAndUntickingTheLastTakesItOut() {
        var draft = found([talk, other])
        draft.setSelecting(true)
        draft.select(1)

        draft.toggle(p360)
        #expect(draft.isIncluded(1))

        draft.toggle(p720)
        draft.toggle(p360)
        #expect(!draft.isIncluded(1))
        #expect(draft.downloads.isEmpty)
    }

    @Test func includingAVideoWhoseRowsWereAllUntickedTicksItsChosenVersionAgain() {
        var draft = found([talk, other])
        draft.setSelecting(true)
        draft.select(1)
        draft.toggle(p720)
        #expect(draft.selectedVersions(of: 1).isEmpty)

        draft.include(1, true)

        #expect(draft.selectedVersions(of: 1) == [p720])
    }

    @Test func eachVideoKeepsItsOwnSelection() {
        var draft = found([talk, other])
        draft.setSelecting(true)
        draft.toggle(p360)
        draft.select(1)
        draft.toggle(p360)

        #expect(draft.selectedVersions(of: 0) == [p1080, p360])
        #expect(draft.selectedVersions(of: 1) == [p720, p360])
    }

    @Test func stoppingSelectingKeepsTheFirstTickedVersionAsTheChoice() {
        var draft = found([talk])
        draft.setSelecting(true)
        draft.toggle(p1080)
        draft.toggle(m4a)
        draft.toggle(opus)

        draft.setSelecting(false)

        #expect(!draft.isSelecting)
        #expect(draft.chosenVersion == m4a)
        #expect(draft.showing == .audio)
        #expect(draft.selectedVersions(of: 0) == [m4a])
    }

    @Test func spaceTicksTheRowTheArrowsMovedTo() {
        var draft = found([talk])
        draft.setSelecting(true)

        draft.moveChoice(by: 1)
        draft.toggleChosen()

        #expect(draft.selectedVersions(of: 0) == [p1080, p720])
    }

    @Test func aSelectionWhoseAddressesChangedWhileCheckingFallsBackToTheChosenVersion() {
        var draft = found([other])
        _ = draft.update(.checkingForMore([other]))
        draft.setSelecting(true)
        draft.toggle(p360)
        draft.include(0, true)

        let renewed720 = Version(source: .file(URL(string: "https://cdn.example.com/720.mp4?token=2")!), totalBytes: 2_000_000, height: 720)
        let renewed360 = Version(source: .file(URL(string: "https://cdn.example.com/360.mp4?token=2")!), totalBytes: 1_000_000, height: 360)
        _ = draft.update(.found([Candidate(label: "Other", versions: [p720, renewed720, renewed360])]))

        #expect(draft.selectedVersions(of: 0) == [p720])
    }

    @Test func checkingForMoreKeepsTheSelection() {
        var draft = found([talk])
        _ = draft.update(.checkingForMore([talk]))
        draft.setSelecting(true)
        draft.toggle(p360)

        let more = Version(source: .file(URL(string: "https://cdn.example.com/2160.mp4")!), height: 2160)
        _ = draft.update(.found([Candidate(label: "Talk", versions: [more, p1080, p720, p360, m4a, opus])]))

        #expect(draft.isSelecting)
        #expect(draft.selectedVersions(of: 0) == [p1080, p360])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SelectingInTheLinkListTests {
    private let page = SentPage(url: URL(string: "https://ftp.example/Season%201/")!)
    private let mkv = Version(source: .file(URL(string: "https://ftp.example/a.mkv")!), height: 720)
    private let small = Version(source: .file(URL(string: "https://ftp.example/a-small.mkv")!), height: 480)

    private func list(_ candidates: [Candidate], probe: @escaping (SentPage, Candidate) async -> Candidate = { $1 }) async throws -> LinkList {
        let list = LinkList(analyze: { _ in AsyncStream { $0.yield(.found(candidates)) } }, probe: probe)
        list.send(page)
        while list.items.count != candidates.count || model(list) == nil { try await Task.sleep(for: .milliseconds(10)) }
        return list
    }

    private func model(_ list: LinkList) -> SentPageModel? {
        if case .video(let model, _)? = list.items.first?.kind { model } else { nil }
    }

    @Test func includeAllTakesEveryVideoButARestrictedOne() async throws {
        let list = try await list([
            Candidate(label: "EP01", versions: [mkv]), Candidate(label: "EP02", versions: [small]),
            Candidate(label: "Locked", versions: [], restriction: .protected),
        ])

        #expect(!list.includesAll)
        list.includeAll(true)

        #expect(list.includesAll)
        #expect(list.downloads.count == 2)
        #expect(list.includedLine == "2 of 3 included")
        list.includeAll(false)
        #expect(list.downloads.isEmpty)
    }

    @Test func includeAllLooksAtVideosNotYetOpened() async throws {
        let waiting = Candidate(label: "Later", versions: [], unprobed: [WatchedRequest(url: URL(string: "https://ftp.example/b.m3u8")!, kind: .manifest)])
        let list = try await list([Candidate(label: "EP01", versions: [mkv]), waiting]) { [small] _, candidate in
            var probed = candidate
            probed.versions = [small]
            probed.unprobed = []
            return probed
        }

        list.includeAll(true)
        while list.isWaiting { try await Task.sleep(for: .milliseconds(10)) }

        #expect(list.downloads.count == 2)
    }

    @Test func theNameFollowsTheOneTickedVersionNotTheRowOnShow() async throws {
        let audio = Version(source: .file(URL(string: "https://ftp.example/a.m4a")!), contentType: "audio/mp4")
        let list = try await list([Candidate(label: "EP01", versions: [mkv, audio])])
        let page = try #require(model(list))
        let id = list.items[0].id

        page.setSelecting(true)
        page.show(.audio)
        #expect(list.chosenVersion(of: id) == mkv)

        list.rename(id, "Pilot.mkv")
        page.toggle(audio)
        page.toggle(mkv)
        #expect(list.chosenVersion(of: id) == audio)
        #expect(list.name(of: id) == nil)
    }

    @Test func tickingVersionsOfAVideoInAListIncludesItWithEveryVersion() async throws {
        let list = try await list([Candidate(label: "EP01", versions: [mkv, small]), Candidate(label: "EP02", versions: [small])])
        let page = try #require(model(list))

        page.setSelecting(true)
        page.toggle(small)

        #expect(list.isIncluded(list.items[0].id))
        #expect(list.downloads.count == 2)
    }
}

struct NamingABatchTests {
    private let h264 = Version(source: .file(URL(string: "https://cdn.example.com/a.mp4")!), contentType: "video/mp4", height: 720, codecs: "H.264")
    private let av1 = Version(source: .file(URL(string: "https://cdn.example.com/b.mp4")!), contentType: "video/mp4", height: 720, codecs: "AV1")
    private let p1080 = Version(source: .file(URL(string: "https://cdn.example.com/c.mp4")!), contentType: "video/mp4", height: 1080)
    private let m4a = Version(source: .file(URL(string: "https://cdn.example.com/d.m4a")!), contentType: "audio/mp4")

    private func names(_ versions: [Version], isTaken: (String) -> Bool = { _ in false }) -> [String] {
        var named: Set<String> = []
        return versions.map { version in
            let name = MediaNaming.fileName(label: "Clip", version: version, alongside: versions, isTaken: isTaken, besides: named)
            named.insert(name)
            return name
        }
    }

    @Test func versionsOfOneVideoEachSayTheirResolutionAndCodecWhenTheyShareOne() {
        #expect(names([h264, p1080, av1]) == ["Clip (720p H.264).mp4", "Clip (1080p).mp4", "Clip (720p AV1).mp4"])
    }

    @Test func aVideoAndItsAudioKeepThePlainName() {
        #expect(names([p1080, m4a]) == ["Clip.mp4", "Clip.m4a"])
    }

    @Test func aLabelThatIsAlreadyAFileNameIsntGivenItsExtensionTwice() {
        let mkv = Version(source: .file(URL(string: "https://ftp.example/EP01.720p.MKV")!), height: 720)

        #expect(MediaNaming.fileName(label: "Show.EP01.720p.MKV", version: mkv) { _ in false } == "Show.EP01.720p.MKV")
        #expect(MediaNaming.fileName(label: "Show.EP01.720p.MKV", version: mkv) { _ in true } == "Show.EP01.720p (720p).MKV")
    }

    @Test func aLoneVersionIsNamedAsBefore() {
        #expect(names([h264], isTaken: { $0 == "Clip.mp4" }) == ["Clip (720p).mp4"])
    }

    @Test func versionsWithNothingToTellThemApartAreNumbered() {
        let bare = Version(source: .file(URL(string: "https://cdn.example.com/x.mp4")!), contentType: "video/mp4")
        let other = Version(source: .file(URL(string: "https://cdn.example.com/y.mp4")!), contentType: "video/mp4")

        #expect(names([bare, other]) == ["Clip.mp4", "Clip 2.mp4"])
    }
}
