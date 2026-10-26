import DowlioCore
import DowlioLibrary
import Foundation
import Testing

/// The New Download sheet's state, apart from the view: which links it has, which need checking,
/// and what Download adds.
struct NewDownloadDraftTests {
    private let folder = URL(filePath: "/tmp/Downloads", directoryHint: .isDirectory)
    private let zip = URL(string: "https://a.com/one.zip")!
    private let iso = URL(string: "https://b.com/two.iso")!

    @Test func aSentLinkFillsTheDraftWithItsPageAsTheReferrer() {
        var draft = NewDownloadDraft(text: "", folder: folder)

        draft.addSent(zip, referrer: URL(string: "https://a.com/downloads"))

        #expect(draft.links == [zip])
        #expect(draft.referrer == "https://a.com/downloads")
    }

    @Test func aLinkSentWhileTheDraftIsOpenJoinsAsAnotherLineAndARepeatMerges() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)

        draft.addSent(iso, referrer: URL(string: "https://b.com/page"))
        draft.addSent(zip, referrer: URL(string: "https://a.com/other"))

        #expect(draft.links == [zip, iso])
        #expect(draft.text == "https://a.com/one.zip\nhttps://b.com/two.iso")
        #expect(draft.referrer == "https://b.com/page")
    }

    @Test func aSentLinksCookiesGoOnlyWithThatLink() {
        var draft = NewDownloadDraft(text: "https://b.com/two.iso", folder: folder)
        let cookies = [Cookie(name: "session", value: "abc")]

        draft.addSent(zip, referrer: nil, cookies: cookies)

        #expect(draft.inspectionOptions(for: zip).cookies == cookies)
        #expect(draft.options(for: zip).cookies == cookies)
        #expect(draft.options(for: iso).cookies.isEmpty)
    }

    @Test func aSentLinkRemembersWhichBrowserSentItAndATypedOneDoesnt() {
        var draft = NewDownloadDraft(text: "https://b.com/two.iso", folder: folder)

        draft.addSent(zip, referrer: nil, browser: "Brave")

        #expect(draft.origin(for: zip) == DownloadOrigin(kind: .sent, browser: "Brave"))
        #expect(draft.origin(for: iso) == nil)
    }

    @Test func aSentLinkBringsTheBrowsersUserAgentUnlessOneWasTyped() {
        var draft = NewDownloadDraft(text: "", folder: folder)
        draft.addSent(zip, referrer: nil, userAgent: "Mozilla/5.0 Dia")
        var typed = NewDownloadDraft(text: "", folder: folder)
        typed.userAgent = "Mine/1.0"
        typed.addSent(zip, referrer: nil, userAgent: "Mozilla/5.0 Dia")

        #expect(draft.options(for: zip).userAgent == "Mozilla/5.0 Dia")
        #expect(typed.options(for: zip).userAgent == "Mine/1.0")
    }

    @Test func aQuickAddDraftMergedIntoAnOpenSheetKeepsWhatEachSentLinkCarried() {
        var sheet = NewDownloadDraft(text: "https://b.com/two.iso", folder: folder)
        var quickAdd = NewDownloadDraft(text: "", folder: folder)
        quickAdd.addSent(zip, referrer: URL(string: "https://a.com/page"), cookies: [Cookie(name: "s", value: "1")], browser: "Arc")

        sheet.merge(quickAdd)

        #expect(sheet.links == [iso, zip])
        #expect(sheet.origin(for: zip) == DownloadOrigin(kind: .sent, browser: "Arc"))
        #expect(sheet.options(for: zip).cookies == [Cookie(name: "s", value: "1")])
        #expect(sheet.referrer == "https://a.com/page")
    }

    @Test func typedLinksCountAtOnce() {
        var draft = NewDownloadDraft(text: "", folder: folder)
        draft.text = "https://a.com/one.zip"

        #expect(draft.links == [zip])
        #expect(draft.canDownload)
    }

    @Test func eachLinkIsCheckedOnceUntilTheHeadersChange() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip\nhttps://b.com/two.iso", folder: folder)

        #expect(draft.linksToCheck() == [zip, iso])
        #expect(draft.check(for: zip) == .checking)
        #expect(draft.linksToCheck().isEmpty)

        draft.referrer = "https://a.com/page"
        #expect(draft.linksToCheck() == [zip, iso])
    }

    @Test func aResultCheckedWithOldHeadersIsIgnored() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)
        _ = draft.linksToCheck()
        let before = draft.inspectionOptions
        draft.userAgent = "Dowlio test"
        _ = draft.linksToCheck()

        draft.record(.failed(.forbidden), for: zip, checkedWith: before)
        #expect(draft.check(for: zip) == .checking)

        draft.record(.inspected(Self.inspection("one.zip")), for: zip, checkedWith: draft.inspectionOptions)
        #expect(draft.check(for: zip) == .inspected(Self.inspection("one.zip")))
    }

    @Test func aRemovedLinkLosesItsCheck() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip\nhttps://b.com/two.iso", folder: folder)
        _ = draft.linksToCheck()
        draft.text = "https://b.com/two.iso"
        _ = draft.linksToCheck()

        draft.record(.inspected(Self.inspection("one.zip")), for: zip, checkedWith: draft.inspectionOptions)
        #expect(draft.check(for: zip) == nil)
    }

    @Test func aSingleLinkShowsItsInspectedNameAndKeepsAnEditOnlyForThatLink() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)
        _ = draft.linksToCheck()
        draft.record(.inspected(Self.inspection("Server Name.zip")), for: zip, checkedWith: draft.inspectionOptions)

        #expect(draft.fileName == "Server Name.zip")
        #expect(draft.options.fileName == nil)

        draft.rename("Mine.zip")
        #expect(draft.fileName == "Mine.zip")
        #expect(draft.options.fileName == "Mine.zip")

        draft.text = "https://b.com/two.iso"
        #expect(draft.fileName == "two.iso")
        #expect(draft.options.fileName == nil)
    }

    @Test func severalLinksNeverGetOneName() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)
        draft.rename("Mine.zip")
        draft.text = "https://a.com/one.zip\nhttps://b.com/two.iso"

        #expect(!draft.isSingleLink)
        #expect(draft.options.fileName == nil)
    }

    @Test func theOptionsCarryTheConnectionsAndOnlyUsableHeaders() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)
        draft.connections = 4
        draft.referrer = "example.com/page"
        draft.userAgent = "   "

        #expect(draft.options.connections == 4)
        #expect(draft.options.referrer == nil)
        #expect(draft.options.userAgent == nil)

        draft.referrer = " https://example.com/page "
        draft.userAgent = "Dowlio test"
        #expect(draft.options.referrer == URL(string: "https://example.com/page"))
        #expect(draft.options.userAgent == "Dowlio test")
    }

    @Test func downloadSaysAnywayWhenALinkCouldntBeChecked() {
        var draft = NewDownloadDraft(text: "https://a.com/one.zip", folder: folder)
        _ = draft.linksToCheck()
        #expect(!draft.downloadsAnyway)

        draft.record(.failed(.notFound), for: zip, checkedWith: draft.inspectionOptions)
        #expect(draft.downloadsAnyway)
    }

    @Test func textWithNoLinkExplainsWhyDownloadIsOff() {
        var draft = NewDownloadDraft(text: "", folder: folder)
        #expect(draft.explanation == nil)

        draft.text = "not a link"
        #expect(!draft.canDownload)
        #expect(draft.explanation == "Paste an http or https link, one per line.")
    }

    @Test func aLinkThatCantBeReachedOffersDownloadAnywayAsItsNextStep() {
        #expect(LinkStatus(failure: .network(NetworkFailure(code: .cannotConnectToHost, message: "")))
            == LinkStatus(line: "Connection lost", reason: "Download Anyway still adds it, and Dowlio tries again when it starts.", tone: .problem))
        #expect(LinkStatus(failure: .tooManyRetries).reason == "Download Anyway still adds it, and Dowlio tries again when it starts.")
    }

    private static func inspection(_ name: String) -> LinkInspection {
        LinkInspection(
            fileName: name, totalBytes: 10, contentType: nil, category: .archives,
            splitsIntoSegments: true, cannotResumeBecause: nil, isNotSecure: false
        )
    }
}
