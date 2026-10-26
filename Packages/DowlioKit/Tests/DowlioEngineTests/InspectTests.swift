import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// What a link is before it's downloaded, for the New Download sheet's file card.
@Suite(.timeLimit(.minutes(1)))
struct InspectTests {
    @Test func aServerWithRangesAndAValidatorIsResumable() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 3 * 1024 * 1024, seed: 91)
        server.serve(.init(data: data, eTag: "\"i1\"", headers: ["Content-Type": "application/zip"]), at: "/files/source.zip")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/files/source.zip"))

        #expect(inspection.fileName == "source.zip")
        #expect(inspection.totalBytes == Int64(data.count))
        #expect(inspection.contentType == "application/zip")
        #expect(inspection.category == .archives)
        #expect(inspection.splitsIntoSegments)
        #expect(inspection.cannotResumeBecause == nil)
        #expect(inspection.isNotSecure)
    }

    @Test func aServerWithoutRangesIsSingleConnectionAndInspectingDownloadsNothing() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 92)
        server.serve(.init(data: data, supportsRanges: false, holdAfterBytes: 64 * 1024), at: "/plain.tar")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/plain.tar"))

        #expect(inspection.totalBytes == Int64(data.count))
        #expect(!inspection.splitsIntoSegments)
        #expect(inspection.cannotResumeBecause == .noRangeSupport)
        #expect(server.requests.count == 1)
    }

    @Test func aServerThatGivesNoSizeCantResumeBecauseTheSizeIsUnknown() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 93), holdAfterBytes: 16 * 1024, omitsLength: true), at: "/live")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/live"))

        #expect(inspection.totalBytes == nil)
        #expect(!inspection.splitsIntoSegments)
        #expect(inspection.cannotResumeBecause == .sizeUnknown)
    }

    @Test func rangesWithoutAValidatorSplitButCantResume() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024, seed: 94)), at: "/nightly.iso")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/nightly.iso"))

        #expect(inspection.splitsIntoSegments)
        #expect(inspection.cannotResumeBecause == .noValidator)
        #expect(inspection.category == .appsAndDiskImages)
    }

    @Test func aRedirectedLinkIsNamedAfterWhereItLeads() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 95), eTag: "\"r1\""), at: "/releases/app-1.2.dmg")
        server.redirect("/download/latest", to: "/releases/app-1.2.dmg")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/download/latest"))

        #expect(inspection.fileName == "app-1.2.dmg")
        #expect(inspection.totalBytes == 1024)
    }

    @Test func aContentDispositionNameWinsAndTheContentTypeDecidesTheCategory() async throws {
        let server = try await TestServer()
        let headers = ["Content-Disposition": #"attachment; filename="Quarterly Report""#, "Content-Type": "application/pdf"]
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 96), eTag: "\"q1\"", headers: headers), at: "/get?id=7")

        let inspection = try await DownloadEngine().inspect(server.url(for: "/get?id=7"))

        #expect(inspection.fileName == "Quarterly Report.pdf")
        #expect(inspection.contentType == "application/pdf")
        #expect(inspection.category == .documents)
    }

    @Test(arguments: [("/article", "article.html"), ("/news/story.php", "story.php.html"), ("/index.html", "index.html")])
    func aWebPageIsNamedAsAnHTMLFile(path: String, name: String) async throws {
        let server = try await TestServer()
        server.serve(.init(data: Data("<html></html>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"]), at: path)

        let inspection = try await DownloadEngine().inspect(server.url(for: path))

        #expect(inspection.fileName == name)
    }

    @Test func aMissingFileThrowsNotFound() async throws {
        let server = try await TestServer()

        await #expect(throws: DownloadError.notFound) {
            try await DownloadEngine().inspect(server.url(for: "/gone.zip"))
        }
    }
}
