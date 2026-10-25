import DowlioCore
import Foundation

enum Incoming: Equatable {
    case pairRequest(code: String, browser: String, version: String, extensionID: String)
    case hello(token: String, version: String)
    case ping
    case catchOffer(CatchOffer)
    case settingsChange(CatchPreferenceChange)
    case linkSend(url: URL, referrer: URL?, browser: String?, cookies: [Cookie])
    case signInGranted(origin: URL, cookies: [Cookie])
    case signInSites([URL])
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
        func cookies() -> [Cookie]? {
            guard let raw = object["cookies"] else { return [] }
            guard let list = raw as? [[String: Any]], list.count <= 300 else { return nil }
            return list.compactMap { entry in
                guard let name = entry["name"] as? String, let value = entry["value"] as? String,
                      Self.isCookieName(name), Self.isCookieValue(value)
                else { return nil }
                return Cookie(name: name, value: value)
            }
        }
        func origin(_ value: Any?) -> URL? {
            guard let text = value as? String, text.count <= 300, let url = URL(string: text), Self.isWebLink(url),
                  let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased()
            else { return nil }
            return URL(string: "\(scheme)://\(host)")
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
            guard let url = link("url"), let cookies = cookies() else { return nil }
            let browserPath = text("browserPath").flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            message = .catchOffer(CatchOffer(
                url: url, finalURL: link("finalUrl"), referrer: link("referrer"),
                mimeType: text("mime"), userAgent: text("userAgent"), browserPath: browserPath, cookies: cookies
            ))
        case "link.send":
            guard let url = link("url"), let cookies = cookies() else { return nil }
            message = .linkSend(url: url, referrer: link("referrer"), browser: text("browser"), cookies: cookies)
        case "signin.granted":
            guard let origin = origin(object["origin"]), let cookies = cookies() else { return nil }
            message = .signInGranted(origin: origin, cookies: cookies)
        case "signin.sites":
            guard let list = object["origins"] as? [Any], list.count <= 500 else { return nil }
            message = .signInSites(list.compactMap(origin))
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
    static func isCookieName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256 && name.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 && $0 != ";" && $0 != "=" }
    }

    static func isCookieValue(_ value: String) -> Bool {
        value.count <= 4096 && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && $0 != ";" }
    }

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
    var origin: String?
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
    static func signInNeeded(_ link: URL) -> Outgoing { Outgoing(type: "signin.needed", url: link.absoluteString) }
    static func signInRevoke(_ origin: URL) -> Outgoing { Outgoing(type: "signin.revoke", origin: origin.absoluteString) }
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
