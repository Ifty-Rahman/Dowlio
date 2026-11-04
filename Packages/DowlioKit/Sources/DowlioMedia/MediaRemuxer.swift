import DowlioCore
import Foundation

public enum MediaRemuxer {
    enum Choice: Equatable {
        case avFoundation
    }

    public static func remux(_ request: RemuxRequest) async throws {
        switch choice(for: request) {
        case .avFoundation:
            try await AVRemuxer.remux(request.tracks, to: request.output)
        }
    }

    static func choice(for request: RemuxRequest) -> Choice {
        .avFoundation
    }
}
