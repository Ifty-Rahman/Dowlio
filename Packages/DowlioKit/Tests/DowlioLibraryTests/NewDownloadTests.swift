import DowlioCore
import DowlioLibrary
import Foundation
import Testing

/// What the New Download sheet makes of pasted text, and what its file card says about a link.
struct NewDownloadTests {
    @Test func oneLinkPerLineInOrderWithBlankLinesIgnored() {
        let lines = PastedLinks.parse("https://a.com/one.zip\n\n  http://b.org/two.iso  \r\nhttps://a.com/three.pdf\n")

        #expect(lines == [
            .link(URL(string: "https://a.com/one.zip")!),
            .link(URL(string: "http://b.org/two.iso")!),
            .link(URL(string: "https://a.com/three.pdf")!),
        ])
    }

    @Test func aRepeatedLinkIsMergedIntoTheFirst() {
        let lines = PastedLinks.parse("https://a.com/one.zip\nhttps://b.com/x\nhttps://a.com/one.zip")

        #expect(lines == [.link(URL(string: "https://a.com/one.zip")!), .link(URL(string: "https://b.com/x")!)])
    }

    @Test(arguments: [
        ("hello there", PastedLinks.Line.notALink("hello there")),
        ("example.com/file.zip", .notALink("example.com/file.zip")),
        ("https://", .notALink("https://")),
        ("ftp://files.example.com/a.iso", .unsupported(URL(string: "ftp://files.example.com/a.iso")!)),
        ("magnet:?xt=urn:btih:abc", .unsupported(URL(string: "magnet:?xt=urn:btih:abc")!)),
        ("HTTPS://Example.com/A.zip", .link(URL(string: "HTTPS://Example.com/A.zip")!)),
    ])
    func eachLineIsALinkOrSaysWhyNot(text: String, line: PastedLinks.Line) {
        #expect(PastedLinks.parse(text) == [line])
    }

    @Test func eachLineExplainsItselfInPlainWords() {
        #expect(PastedLinks.Line.notALink("x").problem == "Not a link")
        #expect(PastedLinks.Line.unsupported(URL(string: "ftp://a/b")!).problem == "Dowlio downloads http and https links")
        #expect(PastedLinks.Line.link(URL(string: "https://a/b")!).problem == nil)
    }

    @Test func checkingComesFirst() {
        #expect(LinkStatus.checking == LinkStatus(line: "Checking link…", reason: nil, tone: .neutral))
    }

    @Test(arguments: [
        (nil as CannotResumeReason?, true, LinkStatus(line: "Resumable, splits into segments", reason: nil, tone: .good)),
        (.noRangeSupport, false, LinkStatus(
            line: "Single connection only", reason: "The server sends the whole file in one piece, so pausing starts it over.", tone: .caution
        )),
        (.sizeUnknown, false, LinkStatus(
            line: "Single connection only", reason: "The server doesn't say how big the file is, so pausing starts it over.", tone: .caution
        )),
        (.noValidator, true, LinkStatus(
            line: "Splits into segments, but can't resume",
            reason: "The server can't confirm the file stays the same, so pausing starts it over.", tone: .caution
        )),
    ])
    func anInspectedLinkSaysWhetherItSplitsAndResumes(cannotResume: CannotResumeReason?, splits: Bool, status: LinkStatus) {
        let inspection = LinkInspection(
            fileName: "a.zip", totalBytes: 1, contentType: nil, category: .archives,
            splitsIntoSegments: splits, cannotResumeBecause: cannotResume, isNotSecure: false
        )
        #expect(LinkStatus(inspection) == status)
    }

    @Test(arguments: ["text/html", "application/xhtml+xml"])
    func aLinkToAWebPageSaysSoAndStillOffersDownload(contentType: String) {
        let inspection = LinkInspection(
            fileName: "article.html", totalBytes: nil, contentType: contentType, category: nil,
            splitsIntoSegments: false, cannotResumeBecause: .sizeUnknown, isNotSecure: false
        )
        #expect(LinkStatus(inspection) == LinkStatus(
            line: "This link is a web page", reason: "Download saves the page as an .html file.", tone: .caution
        ))
    }

    @Test func aLinkThatCantBeInspectedSaysWhyAndWhatToDo() {
        #expect(LinkStatus(failure: .notFound) == LinkStatus(line: "Not found", reason: "The link may have been removed", tone: .problem))
    }
}
