import DowlioCore
import DowlioLibrary
import DowlioStore
import Foundation
import Network

public struct PairingRequest: Equatable, Sendable {
    public let code: String
    public let browser: String
    public let extensionVersion: String

    public init(code: String, browser: String, extensionVersion: String) {
        self.code = code
        self.browser = browser
        self.extensionVersion = extensionVersion
    }
}

public struct SentLink: Sendable {
    public let url: URL
    public let referrer: URL?
    public let browser: String?
    public let cookies: [Cookie]
    public var userAgent: String?
}

public enum ConnectServerError: Error, Equatable {
    case noFreePort
}

public actor ConnectServer {
    public static let defaultPorts: [UInt16] = [51517, 51518, 51519, 51520]
    public static let defaultCatchDeadline: Duration = .seconds(12)
    static let pairingRequestsPerMinute = 5

    private let ports: [UInt16]
    private let store: DownloadStore
    private let vault: any TokenVault
    private let approve: @Sendable (PairingRequest) async -> Bool
    private let now: @Sendable () -> Date
    private let catcher: Catcher?
    private let catchDeadline: Duration
    private let releaseWait: Duration
    private var releases: [ReleaseKey: Release] = [:]
    private let queue = DispatchQueue(label: "io.github.ifty-rahman.Dowlio.connect")
    private var listener: NWListener?
    private var isPairingPending = false
    private var recentPairingRequests: [Date] = []
    private var listenFailed = false
    private let testTimeout: Duration
    private let nameBrowser: @Sendable (String) -> String
    private let extensionVersion: String?
    private let peerApp: @Sendable (NWConnection) -> String?
    private var toldToReload: Set<UUID> = []
    private var justAllowed: [UUID: Date] = [:]
    private let browserChange: AsyncStream<Void>.Continuation
    public nonisolated let browserChanges: AsyncStream<Void>
    static let connectingWindow: TimeInterval = 20
    private var waitingPongs: [String: (session: UUID, answer: CheckedContinuation<LinkTestResult, Never>)] = [:]
    private var sessions: [UUID: Session] = [:]
    private let caught: AsyncStream<CaughtDownload>.Continuation
    private var preferences: CatchPreferences
    private let changeRequests: AsyncStream<CatchPreferenceChange>.Continuation

    public nonisolated let preferenceChanges: AsyncStream<CatchPreferenceChange>
    private let sent: AsyncStream<SentLink>.Continuation

    public nonisolated let sentLinks: AsyncStream<SentLink>

    public nonisolated let catches: AsyncStream<CaughtDownload>

    public init(
        ports: [UInt16] = ConnectServer.defaultPorts,
        store: DownloadStore,
        vault: any TokenVault,
        now: @escaping @Sendable () -> Date = Date.init,
        catcher: Catcher? = nil,
        catchDeadline: Duration = ConnectServer.defaultCatchDeadline,
        releaseWait: Duration = .seconds(2),
        preferences: CatchPreferences = CatchPreferences(),
        testTimeout: Duration = .seconds(2),
        nameBrowser: @escaping @Sendable (String) -> String = { $0 },
        extensionVersion: String? = nil,
        peerApp: @escaping @Sendable (NWConnection) -> String? = { PeerProcess.appName(of: $0) },
        approve: @escaping @Sendable (PairingRequest) async -> Bool
    ) {
        self.catcher = catcher
        self.catchDeadline = catchDeadline
        self.releaseWait = releaseWait
        self.ports = ports
        self.store = store
        self.vault = vault
        self.now = now
        self.approve = approve
        self.testTimeout = testTimeout
        self.nameBrowser = nameBrowser
        self.extensionVersion = extensionVersion
        self.peerApp = peerApp
        self.preferences = preferences
        (catches, caught) = AsyncStream.makeStream()
        (preferenceChanges, changeRequests) = AsyncStream.makeStream()
        (sentLinks, sent) = AsyncStream.makeStream()
        (browserChanges, browserChange) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func publish(_ preferences: CatchPreferences) {
        guard preferences != self.preferences else { return }
        self.preferences = preferences
        for session in sessions.values where session.isOpen && session.pairing != nil {
            send(.settingsUpdate(preferences), to: session)
        }
    }

    public func start() async throws -> UInt16 {
        for port in ports {
            if let listener = try? await listen(on: port) {
                self.listener = listener
                listenFailed = false
                return listener.port?.rawValue ?? port
            }
        }
        listenFailed = true
        throw ConnectServerError.noFreePort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(on port: UInt16) async throws -> NWListener {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = Envelope.maximumSize
        webSocket.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value ?? ""
            let allowed = origin.hasPrefix("chrome-extension://")
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume()
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    once.resume(throwing: error)
                case .cancelled: once.resume(throwing: ConnectServerError.noFreePort)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection)
        sessions = sessions.filter { $0.value.isOpen }
        sessions[session.id] = session
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: session)
    }

    private func receive(on session: Session) {
        session.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data else {
                session.isOpen = false
                session.connection.cancel()
                Task { await self.closed(session) }
                return
            }
            Task {
                if await self.handle(data, on: session) {
                    await self.receive(on: session)
                }
            }
        }
    }

    private func handle(_ data: Data, on session: Session) async -> Bool {
        guard let envelope = Envelope(data) else {
            if session.pairing == nil { return close(session) }

            send(.error("invalidMessage"), to: session)
            return true
        }
        let requestID = envelope.requestID
        await resolveApp(of: session, for: envelope.message)
        switch envelope.message {
        case let .pairRequest(code, browser, version, extensionID):
            Task {
                let reply = await pair(code: code, browser: browser, version: version, extensionID: extensionID, for: session)
                send(reply.replying(to: requestID), to: session)
            }
        case let .hello(token, version):
            guard let pairing = recognise(token, version: version) else {
                send(.helloRejected.replying(to: requestID), to: session, thenClose: true)
                return false
            }
            session.pairing = pairing
            rename(pairing, to: session.appName)
            justAllowed[pairing] = nil
            browserChange.yield()
            send(.helloAccepted.replying(to: requestID), to: session)
            send(.settingsUpdate(preferences), to: session)
            if isOutdated(version), toldToReload.insert(pairing).inserted { send(.extensionReload, to: session) }
        case .ping:
            if let pairing = session.pairing { markSeen(pairing) }
            send(.pong.replying(to: requestID), to: session)
        case .pong:
            guard let pairing = session.pairing else { return close(session) }
            markSeen(pairing)
            if let requestID, let waiting = waitingPongs.removeValue(forKey: requestID) { waiting.answer.resume(returning: .passed) }
        case var .catchOffer(offer):
            guard let pairing = session.pairing else { return close(session) }
            offer.browser = (try? store.browserPairing(pairing))?.browserName
            Task { await take(offer, from: session, replyingTo: requestID) }
        case .catchReleased:
            guard session.pairing != nil else { return close(session) }
            release(ReleaseKey(session: session.id, requestID: requestID))
        case let .linkSend(url, referrer, browser, cookies, userAgent):
            guard let pairing = session.pairing else { return close(session) }
            let name = session.appName ?? browser ?? (try? store.browserPairing(pairing))?.browserName
            sent.yield(SentLink(url: url, referrer: referrer, browser: name, cookies: cookies, userAgent: userAgent))
            send(.linkReceived.replying(to: requestID), to: session)
        case let .settingsChange(change):
            guard session.pairing != nil else { return close(session) }
            changeRequests.yield(change)
        case .unknown:
            guard session.pairing != nil else { return close(session) }
            send(Outgoing.error("unknownType").replying(to: requestID), to: session)
        }
        return true
    }

    private func rename(_ id: UUID, to name: String?) {
        guard let name, var pairing = try? store.browserPairing(id), pairing.browserName != name else { return }
        pairing.browserName = name
        try? store.save(pairing)
    }

    private func resolveApp(of session: Session, for message: Incoming) async {
        guard !session.resolvedApp else { return }
        switch message {
        case .pairRequest, .hello: break
        default: return
        }
        session.resolvedApp = true
        let connection = session.connection
        let lookup = peerApp
        session.appName = await Task.detached { lookup(connection) }.value
    }

    private func pair(code: String, browser: String, version: String, extensionID: String, for session: Session) async -> Outgoing {
        let time = now()
        recentPairingRequests.removeAll { time.timeIntervalSince($0) >= 60 }
        guard recentPairingRequests.count < Self.pairingRequestsPerMinute else { return .pairRefused("tooManyRequests") }
        recentPairingRequests.append(time)
        guard !isPairingPending else { return .pairRefused("busy") }
        isPairingPending = true
        let browser = session.appName ?? nameBrowser(browser)
        let allowed = await approve(PairingRequest(code: code, browser: browser, extensionVersion: version))
        isPairingPending = false
        guard allowed else { return .pairRefused("denied") }
        guard session.isOpen else { return .pairRefused("gone") }
        let token = PairingToken.make()
        let pairing = BrowserPairing(id: UUID(), browserName: browser, extensionID: extensionID, extensionVersion: version, pairedAt: now())
        do {
            try store.save(pairing)
            justAllowed[pairing.id] = now()
            browserChange.yield()
            try vault.save(hash: PairingToken.hash(token), for: pairing.id)
        } catch {
            return .pairRefused("error")
        }
        return .pairApproved(token: token)
    }

    public func browserLinks() -> [BrowserLink] {
        let time = now()
        let open = Set(sessions.values.filter(\.isOpen).compactMap(\.pairing))
        return ((try? store.browserPairings()) ?? []).map { pairing in
            let live = open.contains(pairing.id) && time.timeIntervalSince(pairing.lastSeenAt) <= 60
            let waiting = justAllowed[pairing.id].map { time.timeIntervalSince($0) < Self.connectingWindow } ?? false
            let state: BrowserState = live ? (isOutdated(pairing.extensionVersion) ? .needsReload : .connected) : waiting ? .connecting : .notConnected
            return BrowserLink(id: pairing.id, name: pairing.browserName, state: state)
        }
    }

    public func reload(_ id: UUID) async -> Bool {
        guard let session = sessions.values.first(where: { $0.isOpen && $0.pairing == id }) else { return false }
        return await deliver(.extensionReload, to: session)
    }

    private func isOutdated(_ version: String) -> Bool {
        guard let extensionVersion else { return false }
        return ExtensionVersion.isOlder(version, than: extensionVersion)
    }

    public func test(_ id: UUID) async -> LinkTestResult {
        guard listener != nil else { return listenFailed ? .portInUse : .serverNotListening }
        guard (try? store.browserPairing(id)) != nil else { return .pairingMissing }
        guard let session = sessions.values.first(where: { $0.isOpen && $0.pairing == id }) else { return .notConnected }
        let requestID = "test-\(UUID().uuidString)"
        let deadline = testTimeout
        Task {
            try? await Task.sleep(for: deadline)
            self.giveUp(on: requestID)
        }
        return await withCheckedContinuation { continuation in
            waitingPongs[requestID] = (session.id, continuation)
            send(Outgoing.ping.replying(to: requestID), to: session)
        }
    }

    private func giveUp(on requestID: String) {
        waitingPongs.removeValue(forKey: requestID)?.answer.resume(returning: .noAnswer)
    }

    private func closed(_ session: Session) {
        browserChange.yield()
        for (requestID, waiting) in waitingPongs where waiting.session == session.id {
            waitingPongs.removeValue(forKey: requestID)?.answer.resume(returning: .notConnected)
        }
    }

    private func connectedSession(preferring id: UUID) -> Session? {
        let connected = sessions.values.filter { $0.isOpen && $0.pairing != nil }
        return connected.first { $0.id == id } ?? connected.first
    }

    public func downloadInBrowser(_ download: CaughtDownload) async -> Bool {
        guard let session = connectedSession(preferring: download.session),
              await deliver(.browserDownload(download.link), to: session)
        else { return false }
        await catcher?.discard(download.id)
        return true
    }

    private func deliver(_ message: Outgoing, to session: Session) async -> Bool {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        return await withCheckedContinuation { continuation in
            session.connection.send(content: message.data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func take(_ offer: CatchOffer, from session: Session, replyingTo requestID: String?) async {
        guard let catcher else { return send(Outgoing.catchDeclined(.error).replying(to: requestID), to: session) }
        guard case let .accept(start) = await catcher.decide(offer) else {
            return send(Outgoing.catchDeclined(.unsupported).replying(to: requestID), to: session)
        }
        let key = ReleaseKey(session: session.id, requestID: requestID)
        releases[key] = .awaited
        guard await deliver(Outgoing.catchAccepted.replying(to: requestID), to: session) else {
            releases[key] = nil
            return
        }
        await waitForRelease(key)
        let id = await start()
        func announce(_ row: DownloadRow) {
            caught.yield(CaughtDownload(id: id, link: offer.url, fileName: row.fileName, totalBytes: row.totalBytes, session: session.id))
        }
        switch await catcher.start(of: id, waitingAtMost: catchDeadline) {
        case let .fetching(row):
            announce(row)
        case let .refused(reason, row):
            if let browser = connectedSession(preferring: session.id), await deliver(.browserDownload(offer.url, reason: reason), to: browser) {
                await catcher.discard(id)
            } else {
                announce(row)
            }
        case .removed:
            break
        }
    }

    private func waitForRelease(_ key: ReleaseKey) async {
        guard case .awaited = releases[key] else {
            releases[key] = nil
            return
        }
        let wait = releaseWait
        await withCheckedContinuation { continuation in
            releases[key] = .waiting(continuation)
            Task {
                try? await Task.sleep(for: wait)
                self.release(key)
            }
        }
    }

    private func release(_ key: ReleaseKey) {
        switch releases[key] {
        case .awaited:
            releases[key] = .arrived
        case let .waiting(continuation):
            releases[key] = nil
            continuation.resume()
        case .arrived, nil:
            break
        }
    }

    private func recognise(_ token: String, version: String) -> UUID? {
        guard let id = try? vault.pairing(for: PairingToken.hash(token)), markSeen(id, version: version) else { return nil }
        return id
    }

    @discardableResult
    private func markSeen(_ id: UUID, version: String? = nil) -> Bool {
        guard var pairing = try? store.browserPairing(id) else { return false }
        pairing.markSeen(at: now(), version: version)
        try? store.save(pairing)
        return true
    }

    private func close(_ session: Session) -> Bool {
        session.isOpen = false
        session.connection.cancel()
        browserChange.yield()
        return false
    }

    private func send(_ message: Outgoing, to session: Session, thenClose: Bool = false) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        let connection = session.connection
        connection.send(content: message.data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }
}

struct ReleaseKey: Hashable {
    let session: UUID
    let requestID: String?
}

enum Release {
    case awaited
    case arrived
    case waiting(CheckedContinuation<Void, Never>)
}

final class Session: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    var appName: String?
    var resolvedApp = false
    private let lock = NSLock()
    private var open = true
    var pairing: UUID?

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }

    init(connection: NWConnection) {
        self.connection = connection
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(throwing error: Error? = nil) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
