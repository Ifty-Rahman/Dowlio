import Foundation

enum Incoming: Equatable {
    case pairRequest(code: String, browser: String, version: String, extensionID: String)
    case hello(token: String, version: String)
    case ping
    case catchOffer(CatchOffer)
    case settingsChange(CatchPreferenceChange)
    case linkSend(url: URL, referrer: URL?, browser: String?)
    case unknown(type: String)
}

struct Envelope {
    static let version = 1
    static let maximumSize = 256 * 1024

    let message: Incoming
    let requestID: String?

    init?(_ data: Data) {
        guard data.count <= Self.maximumSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == Self.version,
              let type = object["type"] as? String
        else { return nil }
        requestID = object["requestId"] as? String
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty, value.count <= 200 else { return nil }
            return value
        }
        func link(_ key: String) -> URL? {
            guard let value = object[key] as? String, value.count <= 8192, let url = URL(string: value), Self.isWebLink(url) else { return nil }
            return url
        }
        switch type {
        case "pair.request":
            guard let code = text("code"), code.count == 4, code.allSatisfy(\.isNumber),
                  let browser = text("browser"), let version = text("version"), let id = text("extensionId")
            else { return nil }
            message = .pairRequest(code: code, browser: browser, version: version, extensionID: id)
        case "hello":
            guard let token = text("token"), let version = text("version") else { return nil }
            message = .hello(token: token, version: version)
        case "ping":
            message = .ping
        case "catch.offer":
            guard let url = link("url") else { return nil }
            let browserPath = text("browserPath").flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            message = .catchOffer(CatchOffer(
                url: url, finalURL: link("finalUrl"), referrer: link("referrer"),
                mimeType: text("mime"), userAgent: text("userAgent"), browserPath: browserPath
            ))
        case "link.send":
            guard let url = link("url") else { return nil }
            message = .linkSend(url: url, referrer: link("referrer"), browser: text("browser"))
        case "settings.change":
            let catches = object["catches"] as? Bool
            let site = text("neverCatchSite")
            guard catches != nil || site != nil else { return nil }
            message = .settingsChange(CatchPreferenceChange(catches: catches, neverCatchSite: site))
        default:
            message = .unknown(type: type)
        }
    }
}

extension Envelope {
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}

struct Outgoing: Encodable {
    let v = Envelope.version
    let type: String
    var requestId: String?
    var token: String?
    var reason: String?
    var url: String?
    var catches: Bool?
    var neverCatch: [String]?

    static func pairApproved(token: String) -> Outgoing { Outgoing(type: "pair.approved", token: token) }
    static func pairRefused(_ reason: String) -> Outgoing { Outgoing(type: "pair.refused", reason: reason) }
    static let helloAccepted = Outgoing(type: "hello.ok")
    static let helloRejected = Outgoing(type: "hello.rejected")
    static let pong = Outgoing(type: "pong")
    static func error(_ reason: String) -> Outgoing { Outgoing(type: "error", reason: reason) }
    static let catchAccepted = Outgoing(type: "catch.accepted")
    static let linkReceived = Outgoing(type: "link.received")
    static func settingsUpdate(_ preferences: CatchPreferences) -> Outgoing {
        Outgoing(type: "settings.update", catches: preferences.catches, neverCatch: preferences.neverCatch)
    }
    static func browserDownload(_ link: URL) -> Outgoing { Outgoing(type: "browser.download", url: link.absoluteString) }
    static func catchDeclined(_ reason: CatchDeclineReason) -> Outgoing { Outgoing(type: "catch.declined", reason: reason.rawValue) }

    func replying(to requestID: String?) -> Outgoing {
        var copy = self
        copy.requestId = requestID
        return copy
    }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
