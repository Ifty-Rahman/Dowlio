@testable import DowlioMedia
import Foundation
import Testing

struct PageRedirectTests {
    private let base = URL(string: "https://www.facebook.com/share/r/abc/")!

    @Test func aRefreshTagNamesWhereThePageGoes() {
        let html = "<head><meta http-equiv=\"refresh\" content=\"0;url=https://www.facebook.com/reel/1/?a=b&amp;c=d\" /></head>"
        #expect(HTMLReader(html, base: base).redirect == URL(string: "https://www.facebook.com/reel/1/?a=b&c=d"))
    }

    @Test func aRelativeRefreshTargetIsResolved() {
        let html = "<meta http-equiv=\"Refresh\" content=\"5; URL='/reel/2'\">"
        #expect(HTMLReader(html, base: base).redirect == URL(string: "https://www.facebook.com/reel/2"))
    }

    @Test func aPageWithoutARefreshTagHasNoRedirect() {
        #expect(HTMLReader("<title>Hi</title>", base: base).redirect == nil)
    }
}
