import Testing
@testable import DowlioCore

@Test func bundleIdentifierIsTheReleasedOne() {
    #expect(AppIdentity.bundleIdentifier == "io.github.ifty-rahman.Dowlio")
}

@Test func supportFolderMatchesTheAppName() {
    #expect(AppIdentity.supportFolderName == AppIdentity.name)
}

struct BrowserIdentityTests {
    @Test func theStandardIdentityIsAChromeUserAgentSoSitesOfferEveryQuality() {
        let agent = BrowserIdentity.standard.userAgent ?? ""

        #expect(agent.contains("Chrome/"))
        #expect(agent.contains("Macintosh"))
        #expect(!agent.contains("Version/"))
    }
}
