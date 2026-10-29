import Foundation

enum PlayerControls {
    private static let words = ["loading", "current time", "duration", "remaining time", "play", "pause", "mute", "unmute", "fullscreen", "volume", "seek"]

    static func looksLikeControls(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("player is loading") { return true }
        guard lowered.contains(/\d{1,2}:\d{2}/) else { return false }
        return words.filter { lowered.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }.count >= 2
    }
}

extension SentPage {
    var withoutControlLabels: SentPage {
        var cleaned = self
        cleaned.players = players.map { player in
            var player = player
            if let label = player.label, PlayerControls.looksLikeControls(label) { player.label = nil }
            return player
        }
        return cleaned
    }
}
