import DowlioLibrary
import Foundation
import Testing

struct CouldntReadTests {
    @Test func anAppThatIsntABrowserIsNamedAndTheBrowsersThatWorkAreListed() {
        let reason = CouldntRead.notABrowser("Finder")

        #expect(CouldntRead.title == "Couldn't read the page")
        #expect(reason.explanation == "Finder isn't a browser. Send to Dowlio works in Safari, Chrome, Arc, Brave, Edge and browsers with Dowlio Connect.")
        #expect(!reason.opensAutomationSettings)
    }

    @Test func withNoAppInFrontTheExplanationStillReads() {
        #expect(CouldntRead.notABrowser(nil).explanation == "There's no browser in front. Send to Dowlio works in Safari, Chrome, Arc, Brave, Edge and browsers with Dowlio Connect.")
    }

    @Test func refusedPermissionSaysWhereToTurnItOnAndOffersTheSettings() {
        let reason = CouldntRead.refused("Safari")

        #expect(reason.explanation == "Dowlio isn't allowed to read Safari's page. Turn on Safari under Dowlio in Automation settings, then send the page again.")
        #expect(reason.opensAutomationSettings)
    }

    @Test func aBrowserWithNoPageOrNoAnswerSaysSo() {
        #expect(CouldntRead.noPage("Safari").explanation == "Safari has no web page open in front.")
        #expect(CouldntRead.noAnswer("Dia").explanation == "Dowlio Connect in Dia didn't answer. Send the page from Dowlio Connect's button instead.")
        #expect(!CouldntRead.noPage("Safari").opensAutomationSettings)
        #expect(!CouldntRead.noAnswer("Dia").opensAutomationSettings)
    }

    @Test func askingNamesTheBrowser() {
        #expect(FrontPageState.asking("Safari").line == "Asking Safari for the page")
    }

    @Test func theClipboardsLinkIsItsFirstWebLink() {
        #expect(ClipboardLink.first(in: "see this\nhttps://example.com/watch?v=1\nhttps://example.com/b") == URL(string: "https://example.com/watch?v=1"))
        #expect(ClipboardLink.first(in: "ftp://example.com/a\nhello") == nil)
        #expect(ClipboardLink.first(in: nil) == nil)
    }
}
