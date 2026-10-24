import DowlioCore
import Testing

struct CategoryTests {
    @Test(arguments: [
        ("Holiday.mp4", nil, Category.video),
        ("talk.MKV", nil, .video),
        ("clip.webm", nil, .video),
        ("song.mp3", nil, .audio),
        ("album.flac", nil, .audio),
        ("Quarterly Report.pdf", nil, .documents),
        ("notes.docx", nil, .documents),
        ("data.csv", nil, .documents),
        ("source.zip", nil, .archives),
        ("backup.tar.gz", nil, .archives),
        ("bundle.7z", nil, .archives),
        ("Installer.dmg", nil, .appsAndDiskImages),
        ("ubuntu.iso", nil, .appsAndDiskImages),
        ("Setup.pkg", nil, .appsAndDiskImages),
    ] as [(String, String?, Category)])
    func theExtensionDecides(fileName: String, contentType: String?, expected: Category) {
        #expect(Category(fileName: fileName, contentType: contentType) == expected)
    }

    @Test(arguments: [
        ("watch", "video/mp4", Category.video),
        ("listen", "audio/mpeg; charset=binary", .audio),
        ("report", "application/pdf", .documents),
        ("readme", "text/plain", .documents),
        ("download", "application/zip", .archives),
        ("download", "application/gzip", .archives),
        ("download", "application/x-apple-diskimage", .appsAndDiskImages),
    ] as [(String, String?, Category)])
    func withoutAKnownExtensionTheContentTypeDecides(fileName: String, contentType: String?, expected: Category) {
        #expect(Category(fileName: fileName, contentType: contentType) == expected)
    }

    @Test func theExtensionWinsOverAContentTypeThatDisagrees() {
        #expect(Category(fileName: "movie.mp4", contentType: "application/octet-stream") == .video)
        #expect(Category(fileName: "archive.zip", contentType: "video/mp4") == .archives)
    }

    @Test(arguments: [
        ("blob.dat", nil),
        ("blob.dat", "application/octet-stream"),
        ("download", nil),
        ("page.html", "text/html"),
    ] as [(String, String?)])
    func aFileThatMatchesNeitherHasNoCategory(fileName: String, contentType: String?) {
        #expect(Category(fileName: fileName, contentType: contentType) == nil)
    }

    @Test func eachCategoryHasTheFolderNameTheSidebarShows() {
        #expect(Category.allCases.map(\.folderName) == ["Video", "Audio", "Documents", "Archives", "Apps & Disk Images"])
    }
}
