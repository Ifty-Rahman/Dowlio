import DowlioConnect
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

struct FrontPageTests {
    let safari = FrontApp(name: "Safari", bundleID: "com.apple.Safari")

    @Test func aBrowserWithDowlioConnectIsScannedAndNeverAskedThroughAppleEvents() async {
        let calls = Calls()
        let outcome = await FrontPage.read(FrontApp(name: "Dia", bundleID: "company.thebrowser.dia"), scan: { calls.add("scan \($0)"); return .sent }) { _ in
            calls.add("apple events")
            return nil
        }

        #expect(outcome == .sentThroughConnect)
        #expect(calls.all == ["scan Dia"])
    }

    @Test func aBrowserWithoutDowlioConnectIsReadThroughAppleEventsWithNoCookiesAndNoScan() async {
        let outcome = await FrontPage.read(safari, scan: { _ in .notConnected }) { _ in
            .page(URL(string: "https://example.com/watch?v=1")!, title: "Holiday clip")
        }

        #expect(outcome == .read(SentPage(url: URL(string: "https://example.com/watch?v=1")!, title: "Holiday clip", browser: "Safari")))
        guard case .read(let page) = outcome else { return }
        #expect(page.cookies.isEmpty && page.scan.isEmpty && page.players.isEmpty && page.watched.isEmpty && !page.throughDowlioConnect)
    }

    @Test func anAppThatIsntAScriptableBrowserCouldntBeRead() async {
        let outcome = await FrontPage.read(FrontApp(name: "Finder", bundleID: "com.apple.finder"), scan: { _ in .notConnected }) { _ in nil }

        #expect(outcome == .couldntRead(.notABrowser("Finder")))
    }

    @Test func noAppInFrontCouldntBeReadAndNothingIsAsked() async {
        let calls = Calls()
        let outcome = await FrontPage.read(nil, scan: { calls.add($0); return .sent }) { _ in nil }

        #expect(outcome == .couldntRead(.notABrowser(nil)))
        #expect(calls.all.isEmpty)
    }

    @Test func refusedPermissionCouldntBeRead() async {
        #expect(await FrontPage.read(safari, scan: { _ in .notConnected }) { _ in .refused } == .couldntRead(.refused("Safari")))
    }

    @Test(arguments: ["about:blank", "file:///Users/me/a.html", "favorites://"])
    func aTabThatIsntAWebPageHasNoPage(address: String) async {
        let outcome = await FrontPage.read(safari, scan: { _ in .notConnected }) { _ in .page(URL(string: address)!, title: nil) }

        #expect(outcome == .couldntRead(.noPage("Safari")))
    }

    @Test func aBrowserThatAnswersWithNoPageOrNotAtAllCouldntBeRead() async {
        let dia = FrontApp(name: "Dia", bundleID: nil)
        #expect(await FrontPage.read(dia, scan: { _ in .noPage }) { _ in nil } == .couldntRead(.noPage("Dia")))
        #expect(await FrontPage.read(dia, scan: { _ in .noAnswer }) { _ in nil } == .couldntRead(.noAnswer("Dia")))
        #expect(await FrontPage.read(safari, scan: { _ in .notConnected }) { _ in .noPage } == .couldntRead(.noPage("Safari")))
    }
}

struct ScriptableBrowsersTests {
    @Test(arguments: ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"])
    func chromiumBrowsersAreAskedForTheirFrontWindowsActiveTab(bundleID: String) throws {
        let script = try #require(ScriptableBrowsers.script(for: bundleID))

        #expect(script.contains(#"tell application id "\#(bundleID)""#))
        #expect(script.contains("active tab of front window"))
    }

    @Test func safariIsAskedForItsFrontWindowsCurrentTab() throws {
        let script = try #require(ScriptableBrowsers.script(for: "com.apple.Safari"))

        #expect(script.contains("current tab of front window"))
    }

    @Test(arguments: ["com.apple.finder", "company.thebrowser.dia", "org.mozilla.firefox"])
    func otherAppsAreNotScripted(bundleID: String) {
        #expect(ScriptableBrowsers.script(for: bundleID) == nil)
    }

    @Test func aScriptsReplyGivesTheAddressAndTitle() {
        #expect(ScriptableBrowsers.reply("https://example.com/a\nHoliday clip") == .page(URL(string: "https://example.com/a")!, title: "Holiday clip"))
        #expect(ScriptableBrowsers.reply("https://example.com/a\n") == .page(URL(string: "https://example.com/a")!, title: nil))
        #expect(ScriptableBrowsers.reply("") == .noPage)
    }
}
