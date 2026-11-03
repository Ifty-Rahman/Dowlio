import DowlioCore
import DowlioLibrary
import Foundation
import Testing

struct BrowserSignInDraftTests {
    private let link = URL(string: "https://members.example.com/video/1")!
    private let cookies = [Cookie(name: "session", value: "abc")]

    @Test func aPastedLinkTakesTheBrowsersCookiesForItsCheckAndItsDownload() {
        var draft = NewDownloadDraft(text: link.absoluteString, folder: URL(filePath: "/tmp"))

        draft.addSignIn(for: link, cookies: cookies, userAgent: "Mozilla/5.0 Arc")

        #expect(draft.inspectionOptions(for: link).cookies == cookies)
        #expect(draft.options(for: link).cookies == cookies)
        #expect(draft.userAgent == "Mozilla/5.0 Arc")
    }

    @Test func aLinkTheUserAlreadyGaveAUserAgentKeepsIt() {
        var draft = NewDownloadDraft(text: link.absoluteString, folder: URL(filePath: "/tmp"))
        draft.userAgent = "Custom"

        draft.addSignIn(for: link, cookies: cookies, userAgent: "Mozilla/5.0 Arc")

        #expect(draft.userAgent == "Custom")
    }

    @Test func theCookiesGoWhenTheLinkIsReplaced() {
        var draft = NewDownloadDraft(text: link.absoluteString, folder: URL(filePath: "/tmp"))
        draft.addSignIn(for: link, cookies: cookies, userAgent: nil)

        draft.replace(with: "https://other.example.org/a")
        _ = draft.linksToCheck()

        #expect(draft.inspectionOptions(for: link).cookies.isEmpty)
    }

    @Test func aLinkWithSignInIsDueForCheckingAgain() {
        var draft = NewDownloadDraft(text: link.absoluteString, folder: URL(filePath: "/tmp"))
        #expect(draft.linksToCheck() == [link])
        #expect(draft.linksToCheck().isEmpty)

        draft.addSignIn(for: link, cookies: cookies, userAgent: nil)

        #expect(draft.linksToCheck() == [link])
    }
}
