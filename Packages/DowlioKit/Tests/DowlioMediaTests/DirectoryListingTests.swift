@testable import DowlioMedia
import Foundation
import Testing

struct DirectoryListingTests {
    private let base = URL(string: "https://files.example/videos/")!

    @Test(arguments: [
        "<title>Index of /videos</title>",
        "<title>Directory listing for /videos/</title>",
        "<title>files</title><span>Powered by h5ai</span>",
        "<title>files</title><a href=\"../\">../</a>",
        "<title>files</title><a href=\"/\">Parent Directory</a>",
        "<title>files</title><a href=\"/\">[To Parent Directory]</a>",
    ])
    func aServersFileListingIsRecognised(html: String) {
        #expect(HTMLReader(html, base: base).isDirectoryListing)
    }

    @Test(arguments: [
        "<title>Blog</title><a href=\"..\">Back to the blog</a>",
        "<title>The index of my favourite films</title><video src=\"a.mp4\"></video>",
    ])
    func anOrdinaryPageIsNotAListing(html: String) {
        #expect(!HTMLReader(html, base: base).isDirectoryListing)
    }
}
