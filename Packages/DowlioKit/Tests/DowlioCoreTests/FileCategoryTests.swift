import DowlioCore
import Testing

struct FileCategoryTests {
    @Test(arguments: [
        ("Holiday.mp4", nil, FileCategory.video),
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
    ] as [(String, String?, FileCategory)])
    func theExtensionDecides(fileName: String, contentType: String?, expected: FileCategory) {
        #expect(FileCategory(fileName: fileName, contentType: contentType) == expected)
    }

    @Test(arguments: [
        ("watch", "video/mp4", FileCategory.video),
        ("listen", "audio/mpeg; charset=binary", .audio),
        ("report", "application/pdf", .documents),
        ("readme", "text/plain", .documents),
        ("download", "application/zip", .archives),
        ("download", "application/gzip", .archives),
        ("download", "application/x-apple-diskimage", .appsAndDiskImages),
    ] as [(String, String?, FileCategory)])
    func withoutAKnownExtensionTheContentTypeDecides(fileName: String, contentType: String?, expected: FileCategory) {
        #expect(FileCategory(fileName: fileName, contentType: contentType) == expected)
    }

    @Test func theExtensionWinsOverAContentTypeThatDisagrees() {
        #expect(FileCategory(fileName: "movie.mp4", contentType: "application/octet-stream") == .video)
        #expect(FileCategory(fileName: "archive.zip", contentType: "video/mp4") == .archives)
    }

    @Test(arguments: [
        ("blob.dat", nil),
        ("blob.dat", "application/octet-stream"),
        ("download", nil),
        ("page.html", "text/html"),
    ] as [(String, String?)])
    func aFileThatMatchesNeitherHasNoCategory(fileName: String, contentType: String?) {
        #expect(FileCategory(fileName: fileName, contentType: contentType) == nil)
    }

    @Test func eachCategoryHasTheFolderNameTheSidebarShows() {
        #expect(FileCategory.allCases.map(\.folderName) == ["Video", "Audio", "Documents", "Archives", "Apps & Disk Images"])
    }
}
