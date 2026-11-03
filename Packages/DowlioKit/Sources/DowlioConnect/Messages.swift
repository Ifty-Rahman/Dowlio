import DowlioCore
import DowlioMedia
import Foundation

enum Incoming: Equatable {
    case pairRequest(browser: String, version: String, extensionID: String)
    case pairCode(String)
    case hello(key: String, nonce: String, version: String)
    case helloProof(String)
    case legacyHello(token: String)
    case ping
    case pong
    case catchOffer(CatchOffer)
    case catchReleased
    case settingsChange(CatchPreferenceChange)
    case linkSend(url: URL, referrer: URL?, browser: String?, cookies: [Cookie], userAgent: String?)
    case pageSend(SentPage)
    case pageNone
    case siteSignIn(cookies: [Cookie], userAgent: String?)
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
                let domain = (entry["domain"] as? String).flatMap { Self.isCookieDomain($0) ? $0 : nil }
                let path = (entry["path"] as? String).flatMap { $0.hasPrefix("/") && Self.isCookieValue($0) ? $0 : nil }
                return Cookie(
                    name: name, value: value, domain: domain, path: path, hostOnly: entry["hostOnly"] as? Bool ?? false,
                    secure: entry["secure"] as? Bool ?? false, httpOnly: entry["httpOnly"] as? Bool ?? true
                )
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
            guard let browser = text("browser"), let version = text("version"), let id = text("extensionId") else { return nil }
            message = .pairRequest(browser: browser, version: version, extensionID: id)
        case "pair.code":
            guard let code = text("code"), code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            message = .pairCode(code)
        case "hello":
            if let key = text("key"), let nonce = text("nonce"), let version = text("version"),
               Self.isProofText(key), Self.isProofText(nonce) {
                message = .hello(key: key, nonce: nonce, version: version)
            } else if let token = text("token") {
                message = .legacyHello(token: token)
            } else {
                return nil
            }
        case "hello.proof":
            guard let proof = text("proof"), Self.isProofText(proof) else { return nil }
            message = .helloProof(proof)
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
        case "page.send":
            guard let url = link("url"), let cookies = cookies() else { return nil }
            let scan = PageScan(object)
            let watched = ((object["requests"] as? [[String: Any]]) ?? []).prefix(Self.maximumScannedMedia).compactMap { entry -> WatchedRequest? in
                guard let value = entry["url"] as? String, value.count <= 8192, let address = URL(string: value), Self.isWebLink(address),
                      let kind = (entry["kind"] as? String).flatMap(WatchedRequest.Kind.init(rawValue:)) else { return nil }
                let referrer = (entry["referrer"] as? String).flatMap(URL.init(string:)).flatMap { Self.isWebLink($0) ? $0 : nil }
                let contentType = (entry["contentType"] as? String).flatMap { !$0.isEmpty && $0.count <= 200 ? $0 : nil }
                return WatchedRequest(url: address, kind: kind, contentType: contentType, referrer: referrer)
            }
            message = .pageSend(SentPage(
                url: url, title: text("title", limit: 1000), browser: text("browser"), cookies: cookies,
                userAgent: text("userAgent", limit: Self.maximumHeaderValue), scan: scan.media, players: scan.players, embeddedJSON: scan.embeddedJSON,
                watched: Array(watched), throughDowlioConnect: true
            ))
        case "page.none":
            guard requestID != nil else { return nil }
            message = .pageNone
        case "site.signIn":
            guard requestID != nil, let cookies = cookies() else { return nil }
            message = .siteSignIn(cookies: cookies, userAgent: text("userAgent", limit: Self.maximumHeaderValue))
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
    static let maximumScannedMedia = PageScan.maximumMedia
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

    static func isCookieDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.count <= 253 && domain.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
        }
    }

    static func isCookieValue(_ value: String) -> Bool {
        value.count <= 4096 && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && $0 != ";" }
    }

    static func isProofText(_ text: String) -> Bool {
        (16...88).contains(text.count) && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    static func isWebLink(_ url: URL) -> Bool {
        PageScan.isWebLink(url)
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
    var nonce: String?
    var proof: String?
    var left: Int?

    static func pairApproved(token: String) -> Outgoing { Outgoing(type: "pair.approved", token: token) }
    static func pairRefused(_ reason: String) -> Outgoing { Outgoing(type: "pair.refused", reason: reason) }
    static let pairCodeNeeded = Outgoing(type: "pair.codeNeeded")
    static func pairCodeWrong(left: Int) -> Outgoing { Outgoing(type: "pair.codeWrong", left: left) }
    static func helloChallenge(nonce: String, proof: String) -> Outgoing { Outgoing(type: "hello.challenge", nonce: nonce, proof: proof) }
    static let helloAccepted = Outgoing(type: "hello.ok")
    static let helloRejected = Outgoing(type: "hello.rejected")
    static let pong = Outgoing(type: "pong")
    static let ping = Outgoing(type: "ping")
    static let extensionReload = Outgoing(type: "extension.reload")
    static func error(_ reason: String) -> Outgoing { Outgoing(type: "error", reason: reason) }
    static let catchAccepted = Outgoing(type: "catch.accepted")
    static let linkReceived = Outgoing(type: "link.received")
    static let pageReceived = Outgoing(type: "page.received")
    static let pageScan = Outgoing(type: "page.scan")
    static func siteSignIn(for link: URL) -> Outgoing { Outgoing(type: "site.signIn", url: link.absoluteString) }
    static func settingsUpdate(_ preferences: CatchPreferences) -> Outgoing {
        Outgoing(
            type: "settings.update", catches: preferences.catches, neverCatch: preferences.neverCatch
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
