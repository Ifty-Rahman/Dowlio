import Testing
@testable import DowlioCore

@Test func bundleIdentifierIsTheReleasedOne() {
    #expect(AppIdentity.bundleIdentifier == "io.github.ifty-rahman.Dowlio")
}

@Test func supportFolderMatchesTheAppName() {
    #expect(AppIdentity.supportFolderName == AppIdentity.name)
}
