import DowlioCore
import Foundation

public struct SubtitlePreference: Equatable, Sendable {
    public var downloads: Bool
    public var languages: [String]

    public init(downloads: Bool, languages: [String]) {
        self.downloads = downloads
        self.languages = languages
    }

    public static let off = SubtitlePreference(downloads: false, languages: [])

    public static var macLanguages: [String] {
        var seen = Set<String>()
        return Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier }.filter { seen.insert($0).inserted }
    }
}

enum SubtitleSelection {
    static let formats = ["vtt", "srt"]

    static func choose(_ info: MediaInfo, for preference: SubtitlePreference) -> [MediaExtras.Subtitle] {
        guard preference.downloads else { return [] }
        let chosen = preference.languages.compactMap { language in
            uploaded(info, language) ?? automatic(info, language)
        }
        if !chosen.isEmpty { return chosen }
        guard let first = preference.languages.first, let translated = translation(info, into: first) else { return [] }
        return [translated]
    }

    private static func base(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    private static func uploaded(_ info: MediaInfo, _ language: String) -> MediaExtras.Subtitle? {
        let keys = info.subtitles.keys.filter { $0 != "live_chat" && base($0) == base(language) }.sorted { $0.count < $1.count }
        for key in keys {
            if let subtitle = subtitle(info.subtitles[key] ?? [], language: language) { return subtitle }
        }
        return nil
    }

    private static func automatic(_ info: MediaInfo, _ language: String) -> MediaExtras.Subtitle? {
        let keys = info.automaticCaptions.keys.filter { base($0) == base(language) }.sorted { ($0.hasSuffix("-orig") ? 0 : 1, $0.count) < ($1.hasSuffix("-orig") ? 0 : 1, $1.count) }
        for key in keys {
            let tracks = (info.automaticCaptions[key] ?? []).filter { !$0.isTranslation }
            if let subtitle = subtitle(tracks, language: language) { return subtitle }
        }
        return nil
    }

    private static func translation(_ info: MediaInfo, into language: String) -> MediaExtras.Subtitle? {
        let keys = info.automaticCaptions.keys.filter { base($0) == base(language) }.sorted { $0.count < $1.count }
        for key in keys {
            let tracks = (info.automaticCaptions[key] ?? []).filter(\.isTranslation)
            if let subtitle = subtitle(tracks, language: language) { return subtitle }
        }
        return nil
    }

    private static func subtitle(_ tracks: [MediaInfo.TextTrack], language: String) -> MediaExtras.Subtitle? {
        for format in formats {
            if let track = tracks.first(where: { $0.ext == format }), let url = track.url {
                let name = Locale.current.localizedString(forLanguageCode: base(language)) ?? language
                return MediaExtras.Subtitle(language: base(language), name: name, url: url, format: format)
            }
        }
        return nil
    }
}
