import AVFoundation
import CommonCrypto
import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct EncryptedStreamTests {
    private let key = Data((0..<16).map { UInt8($0 * 7 % 256) })

    private func encrypt(_ data: Data, iv: Data) -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                            out.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return output.prefix(moved)
    }

    private func sequenceIV(_ number: UInt8) -> Data { Data(repeating: 0, count: 15) + [number] }

    @Test func anAES128StreamIsDecryptedIntoAPlayableFile() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        server.serve(TestServer.File(data: key), at: "/keys/k1")
        let explicitIV = Data((100..<116).map { UInt8($0) })
        for (index, name) in ["ts0.ts", "ts1.ts", "ts2.ts"].enumerated() {
            let iv = index == 2 ? explicitIV : sequenceIV(UInt8(5 + index))
            server.serve(TestServer.File(data: encrypt(try TestMedia.data(name), iv: iv)), at: "/enc/\(index).ts")
        }
        let playlist = try M3U8Parser.parse("""
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:5
            #EXT-X-KEY:METHOD=AES-128,URI="/keys/k1"
            #EXTINF:1,
            /enc/0.ts
            #EXTINF:1,
            /enc/1.ts
            #EXT-X-KEY:METHOD=AES-128,URI="/keys/k1",IV=0x\(explicitIV.map { String(format: "%02x", $0) }.joined())
            #EXTINF:1,
            /enc/2.ts
            #EXT-X-ENDLIST
            """, base: server.url(for: "/enc/index.m3u8"))
        guard case .media(let media) = playlist else { Issue.record("not media"); return }
        var options = RequestOptions()
        options.fileName = "Secret.mp4"

        let id = await fixture.library.add(
            .media(try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: media.fragments)])),
            destination: .folder(fixture.folder), options: options
        )
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Secret.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
        #expect(server.requests.filter { $0.path == "/keys/k1" }.count == 1)
    }
}
