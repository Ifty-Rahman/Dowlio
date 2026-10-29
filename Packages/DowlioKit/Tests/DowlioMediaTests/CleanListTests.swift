import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CleanListTests {
    @Test func aSentTubePageListsOneRowPerResolutionAndCodecWithNoStreamPiecesAndACleanLabel() async throws {
        let site = try await Site()
        let page = try SentFixture.serve("tube-hls-av1", on: site)

        let found = try await site.analyze(page.path) { $0 = page.sent }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Holiday clip - TUBE"])
        let rows = candidates.first?.versions ?? []
        #expect(rows.map(\.source.url.lastPathComponent) == ["1-240p-av1.mp4", "1-240p.mp4", "1-360p-av1.mp4", "1-360p.mp4"])
        #expect(rows.map(\.height) == [240, 240, 360, 360])
        #expect(rows.map(\.codecs) == ["AV1", nil, "AV1", nil])
        #expect(rows.allSatisfy { ($0.totalBytes ?? 0) > 1_000_000 })
    }

    @Test func aResolutionIsReadFromAnAddressOnlyWhenItNamesOne() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/v/1-,240p,360p,720p,.urlset/clip.mp4")
        site.serve(video: 3_000_000, at: "/v/1-720p.mp4")

        let found = try await site.analyze("/watch") {
            $0.watched = ["/v/1-,240p,360p,720p,.urlset/clip.mp4", "/v/1-720p.mp4"].map {
                WatchedRequest(url: site.url($0), kind: .file, contentType: "video/mp4")
            }
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).map(\.height).sorted { ($0 ?? 0) < ($1 ?? 0) } == [nil, 720])
    }

    @Test func aDownloadLinkShowsTheCodecItsTextNamesAndNoneOtherwise() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>Clip</title>
            <a href="/dload/720/1-720p.mp4">Download MP4 (H.264) 720p</a>
            <a href="/dload/720/1-720p-av1.mp4">Download AV1 720p</a>
            <a href="/dload/480/1-480p.mp4">Download 480p</a>
            <a href="/dload/480/1-480p-av1.mp4">Download 480p</a>
            """, at: "/watch")
        for path in ["/dload/720/1-720p.mp4", "/dload/720/1-720p-av1.mp4", "/dload/480/1-480p.mp4", "/dload/480/1-480p-av1.mp4"] {
            site.serve(video: 2_000_000, at: path)
        }

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let rows = candidates.flatMap(\.versions).map { "\($0.source.url.lastPathComponent) \($0.codecs ?? "-")" }
        #expect(rows == ["1-480p.mp4 -", "1-480p-av1.mp4 AV1", "1-720p.mp4 H.264", "1-720p-av1.mp4 AV1"])
    }

    @Test func aLabelNeverComesFromAPlayersControls() async throws {
        let site = try await Site()
        site.serve(html: "<title>Holiday clip</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/clip.mp4")

        let found = try await site.analyze("/watch") {
            $0.title = nil
            $0.players = [ScannedPlayer(group: 1, label: "Play Mute Current Time 0:00 / Duration 3:12 Fullscreen", visibility: 1)]
            $0.scan = [ScannedMedia(url: site.url("/clip.mp4"), kind: .video, group: 1)]
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Holiday clip"])
    }

    @Test func aLabelThatIsOnlyAControlsPhraseIsDropped() async throws {
        let site = try await Site()
        site.serve(html: "<title>Launch day</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/clip.mp4")

        let found = try await site.analyze("/watch") {
            $0.players = [ScannedPlayer(group: 1, label: "Audio is muted", visibility: 1)]
            $0.scan = [ScannedMedia(url: site.url("/clip.mp4"), kind: .video, group: 1)]
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Launch day"])
    }

    @Test func aTitleWithOneControlWordAndATimeIsKept() async throws {
        let site = try await Site()
        site.serve(html: "<title>Page</title>", at: "/watch")
        site.serve(video: 2_000_000, at: "/clip.mp4")

        let found = try await site.analyze("/watch") {
            $0.players = [ScannedPlayer(group: 1, label: "Play It Again 2:30 Mix", visibility: 1)]
            $0.scan = [ScannedMedia(url: site.url("/clip.mp4"), kind: .video, group: 1)]
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Play It Again 2:30 Mix"])
    }

    @Test func aWatchedFileAPlaylistListsIsNeverAVersion() async throws {
        let site = try await Site()
        site.serve(html: "<title>Stream</title>", at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-TARGETDURATION:10
            #EXT-X-MAP:URI="/parts/header.mp4"
            #EXTINF:10.0,
            /parts/a.mp4
            #EXTINF:10.0,
            /parts/b.mp4
            #EXT-X-ENDLIST
            """, at: "/hls/clip.m3u8")
        site.serve(video: 2_000_000, at: "/parts/header.mp4")
        site.serve(video: 2_000_000, at: "/parts/a.mp4")
        site.serve(video: 2_000_000, at: "/parts/b.mp4")

        let found = try await site.analyze("/watch") {
            $0.watched = [
                WatchedRequest(url: site.url("/hls/clip.m3u8"), kind: .manifest, contentType: "application/vnd.apple.mpegurl"),
                WatchedRequest(url: site.url("/parts/header.mp4"), kind: .file, contentType: "video/mp4"),
                WatchedRequest(url: site.url("/parts/a.mp4"), kind: .file, contentType: "video/mp4"),
            ]
        }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let versions = candidates.flatMap(\.versions)
        #expect(versions.count == 1)
        #expect(versions.allSatisfy { if case .media = $0.source { true } else { false } })
    }
}

struct SentFixture {
    var path: String
    var sent: SentPage

    static func serve(_ name: String, on site: Site) throws -> SentFixture {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Sent/\(name)", withExtension: "json"))
        let server = site.url("/").absoluteString.dropLast()
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "{{server}}", with: server)
        let fixture = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let path = try #require(fixture["page"] as? String)
        for file in fixture["files"] as? [[String: Any]] ?? [] {
            let at = try #require(file["path"] as? String)
            let type = file["type"] as? String ?? "application/octet-stream"
            if let body = file["text"] as? String {
                site.serve(text: body, type: type, at: at)
            } else {
                site.serve(video: file["bytes"] as? Int ?? 0, type: type, at: at)
            }
        }
        if let html = fixture["html"] as? String { site.serve(html: html, at: path) }
        var sent = SentPage(url: site.url(path), throughDowlioConnect: true)
        sent.players = (fixture["players"] as? [[String: Any]] ?? []).map { player in
            ScannedPlayer(
                group: player["group"] as? Int ?? 0, label: player["label"] as? String,
                poster: (player["poster"] as? String).flatMap(URL.init(string:)), duration: player["duration"] as? Double,
                visibility: player["visibility"] as? Double ?? 0, origin: (player["origin"] as? String).flatMap(URL.init(string:))
            )
        }
        sent.scan = (fixture["scan"] as? [String] ?? []).compactMap(URL.init(string:)).map { ScannedMedia(url: $0, kind: .video) }
        sent.watched = (fixture["watched"] as? [[String: Any]] ?? []).compactMap { request in
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return WatchedRequest(
                url: url, kind: request["kind"] as? String == "manifest" ? .manifest : .file,
                contentType: request["type"] as? String, referrer: site.url("/")
            )
        }
        return SentFixture(path: path, sent: sent)
    }
}
