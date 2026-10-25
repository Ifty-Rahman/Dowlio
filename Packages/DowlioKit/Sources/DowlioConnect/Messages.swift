import DowlioCore
import Foundation

enum Incoming: Equatable {
    case pairRequest(code: String, browser: String, version: String, extensionID: String)
    case hello(token: String, version: String)
    case ping
    case pong
    case catchOffer(CatchOffer)
    case catchReleased
    case settingsChange(CatchPreferenceChange)
    case linkSend(url: URL, referrer: URL?, browser: String?, cookies: [Cookie], userAgent: String?)
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
        func text(_ key: String, limit: Int = 200) -> String? {
            guard let value = object[key] as? String, !value.isEmpty, value.count <= limit else { return nil }
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
        func browserRequest() -> BrowserRequest? {
            guard let raw = object["request"] as? [String: Any] else { return nil }
            let method = (raw["method"] as? String)?.uppercased() ?? "GET"
            guard Self.replayedMethods.contains(method) else { return nil }
            var body: Data?
            if method == "POST", let encoded = raw["body"] as? String {
                guard let decoded = Data(base64Encoded: encoded), decoded.count <= Self.maximumBody else { return nil }
                body = decoded
            }
            let headers = ((raw["headers"] as? [[String: Any]]) ?? []).prefix(Self.maximumHeaders).compactMap { entry -> Header? in
                guard let name = entry["name"] as? String, let value = entry["value"] as? String,
                      Self.isReplayedHeader(name), Self.isHeaderValue(value)
                else { return nil }
                return Header(name: name, value: value)
            }
            let request = BrowserRequest(method: method, body: body, headers: Array(headers))
            return request.isEmpty ? nil : request
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
        case "pong":
            message = .pong
        case "catch.offer":
            guard let url = link("url"), let cookies = cookies() else { return nil }
            message = .catchOffer(CatchOffer(
                url: url, finalURL: link("finalUrl"), referrer: link("referrer"),
                mimeType: text("mime"), userAgent: text("userAgent", limit: Self.maximumHeaderValue),
                cookies: cookies, browserRequest: browserRequest()
            ))
        case "catch.released":
            guard requestID != nil else { return nil }
            message = .catchReleased
        case "link.send":
            guard let url = link("url"), let cookies = cookies() else { return nil }
            message = .linkSend(
                url: url, referrer: link("referrer"), browser: text("browser"), cookies: cookies,
                userAgent: text("userAgent", limit: Self.maximumHeaderValue)
            )
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
    static let replayedMethods: Set<String> = ["GET", "POST"]
    static let maximumBody = 64 * 1024
    static let maximumHeaders = 40
    static let maximumHeaderValue = 4096
    static let unreplayedHeaders: Set<String> = [
        "host", "cookie", "range", "if-range", "content-length", "connection", "keep-alive", "accept-encoding",
        "transfer-encoding", "te", "trailer", "upgrade", "expect", "proxy-authorization", "proxy-connection",
        "user-agent", "referer",
    ]

    static func isReplayedHeader(_ name: String) -> Bool {
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.count <= 100 && name.unicodeScalars.allSatisfy(tokenCharacters.contains)
            && !unreplayedHeaders.contains(name.lowercased())
    }

    static func isHeaderValue(_ value: String) -> Bool {
        value.count <= maximumHeaderValue && value.unicodeScalars.allSatisfy { ($0.value >= 32 && $0.value != 127) || $0 == "\t" }
    }

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
    var signIn: Bool?
    var noSignIn: [String]?
    var catches: Bool?
    var neverCatch: [String]?

    static func pairApproved(token: String) -> Outgoing { Outgoing(type: "pair.approved", token: token) }
    static func pairRefused(_ reason: String) -> Outgoing { Outgoing(type: "pair.refused", reason: reason) }
    static let helloAccepted = Outgoing(type: "hello.ok")
    static let helloRejected = Outgoing(type: "hello.rejected")
    static let pong = Outgoing(type: "pong")
    static let ping = Outgoing(type: "ping")
    static let extensionReload = Outgoing(type: "extension.reload")
    static func error(_ reason: String) -> Outgoing { Outgoing(type: "error", reason: reason) }
    static let catchAccepted = Outgoing(type: "catch.accepted")
    static let linkReceived = Outgoing(type: "link.received")
    static func settingsUpdate(_ preferences: CatchPreferences) -> Outgoing {
        Outgoing(
            type: "settings.update", signIn: preferences.sharesSignIn, noSignIn: preferences.noSignIn,
            catches: preferences.catches, neverCatch: preferences.neverCatch
        )
    }
    static func browserDownload(_ link: URL, reason: CatchDeclineReason? = nil) -> Outgoing {
        Outgoing(type: "browser.download", reason: reason?.rawValue, url: link.absoluteString)
    }
    static func catchDeclined(_ reason: CatchDeclineReason) -> Outgoing { Outgoing(type: "catch.declined", reason: reason.rawValue) }

    func replying(to requestID: String?) -> Outgoing {
        var copy = self
        copy.requestId = requestID
        return copy
    }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
