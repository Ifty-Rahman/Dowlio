import DowlioCore
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
    let session: UUID
}

public struct SignInGrant: Sendable {
    public let origin: URL
    public let cookies: [Cookie]
}

public enum ConnectServerError: Error, Equatable {
    case noFreePort
}

public actor ConnectServer {
    public static let defaultPorts: [UInt16] = [51517, 51518, 51519, 51520]
    static let pairingRequestsPerMinute = 5

    private let ports: [UInt16]
    private let store: DownloadStore
    private let vault: any TokenVault
    private let approve: @Sendable (PairingRequest) async -> Bool
    private let now: @Sendable () -> Date
    private let catcher: Catcher?
    private let catchDeadline: Duration
    private let queue = DispatchQueue(label: "io.github.ifty-rahman.Dowlio.connect")
    private var listener: NWListener?
    private var isPairingPending = false
    private var recentPairingRequests: [Date] = []
    private var sessions: [UUID: Session] = [:]
    private let caught: AsyncStream<CaughtDownload>.Continuation
    private var preferences: CatchPreferences
    private let changeRequests: AsyncStream<CatchPreferenceChange>.Continuation

    public nonisolated let preferenceChanges: AsyncStream<CatchPreferenceChange>
    private let sent: AsyncStream<SentLink>.Continuation

    public nonisolated let sentLinks: AsyncStream<SentLink>
    private let granted: AsyncStream<SignInGrant>.Continuation
    public nonisolated let signInGrants: AsyncStream<SignInGrant>
    private let sitesChanged: AsyncStream<[URL]>.Continuation
    public nonisolated let allowedSites: AsyncStream<[URL]>
    private var sitesByBrowser: [UUID: [URL]] = [:]

    public nonisolated let catches: AsyncStream<CaughtDownload>

    public init(
        ports: [UInt16] = ConnectServer.defaultPorts,
        store: DownloadStore,
        vault: any TokenVault,
        now: @escaping @Sendable () -> Date = Date.init,
        catcher: Catcher? = nil,
        catchDeadline: Duration = .seconds(4),
        preferences: CatchPreferences = CatchPreferences(),
        approve: @escaping @Sendable (PairingRequest) async -> Bool
    ) {
        self.catcher = catcher
        self.catchDeadline = catchDeadline
        self.ports = ports
        self.store = store
        self.vault = vault
        self.now = now
        self.approve = approve
        self.preferences = preferences
        (catches, caught) = AsyncStream.makeStream()
        (preferenceChanges, changeRequests) = AsyncStream.makeStream()
        (sentLinks, sent) = AsyncStream.makeStream()
        (signInGrants, granted) = AsyncStream.makeStream()
        (allowedSites, sitesChanged) = AsyncStream.makeStream()
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
                return port
            }
        }
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
            send(.helloAccepted.replying(to: requestID), to: session)
            send(.settingsUpdate(preferences), to: session)
        case .ping:
            if let pairing = session.pairing { markSeen(pairing) }
            send(.pong.replying(to: requestID), to: session)
        case var .catchOffer(offer):
            guard let pairing = session.pairing else { return close(session) }
            offer.browser = (try? store.browserPairing(pairing))?.browserName
            Task {
                let reply = await answer(offer, from: session)
                send(reply.replying(to: requestID), to: session)
            }
        case let .linkSend(url, referrer, browser, cookies):
            guard let pairing = session.pairing else { return close(session) }
            let name = browser ?? (try? store.browserPairing(pairing))?.browserName
            sent.yield(SentLink(url: url, referrer: referrer, browser: name, cookies: cookies, session: session.id))
            send(.linkReceived.replying(to: requestID), to: session)
        case let .signInGranted(origin, cookies):
            guard session.pairing != nil else { return close(session) }
            granted.yield(SignInGrant(origin: origin, cookies: cookies))
        case let .signInSites(origins):
            guard let pairing = session.pairing else { return close(session) }
            sitesByBrowser[pairing] = origins
            sitesChanged.yield(currentSites())
        case let .settingsChange(change):
            guard session.pairing != nil else { return close(session) }
            changeRequests.yield(change)
        case .unknown:
            guard session.pairing != nil else { return close(session) }
            send(Outgoing.error("unknownType").replying(to: requestID), to: session)
        }
        return true
    }

    private func pair(code: String, browser: String, version: String, extensionID: String, for session: Session) async -> Outgoing {
        let time = now()
        recentPairingRequests.removeAll { time.timeIntervalSince($0) >= 60 }
        guard recentPairingRequests.count < Self.pairingRequestsPerMinute else { return .pairRefused("tooManyRequests") }
        recentPairingRequests.append(time)
        guard !isPairingPending else { return .pairRefused("busy") }
        isPairingPending = true
        let allowed = await approve(PairingRequest(code: code, browser: browser, extensionVersion: version))
        isPairingPending = false
        guard allowed else { return .pairRefused("denied") }
        guard session.isOpen else { return .pairRefused("gone") }
        let token = PairingToken.make()
        let pairing = BrowserPairing(id: UUID(), browserName: browser, extensionID: extensionID, extensionVersion: version, pairedAt: now())
        do {
            try store.save(pairing)
            try vault.save(hash: PairingToken.hash(token), for: pairing.id)
        } catch {
            return .pairRefused("error")
        }
        return .pairApproved(token: token)
    }

    public func askForSignIn(_ link: SentLink) async -> Bool {
        guard let session = connectedSession(preferring: link.session) else { return false }
        return await deliver(.signInNeeded(link.url), to: session)
    }

    public func revokeSignIn(_ origin: URL) {
        for (id, sites) in sitesByBrowser { sitesByBrowser[id] = sites.filter { $0 != origin } }
        for session in sessions.values where session.isOpen && session.pairing != nil {
            send(.signInRevoke(origin), to: session)
        }
        sitesChanged.yield(currentSites())
    }

    private func currentSites() -> [URL] {
        Array(Set(sitesByBrowser.values.flatMap { $0 })).sorted { $0.absoluteString < $1.absoluteString }
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

    private func answer(_ offer: CatchOffer, from session: Session) async -> Outgoing {
        guard let catcher else { return .catchDeclined(.error) }
        let deadline = catchDeadline
        let decision = await withTaskGroup(of: CatchDecision?.self) { group in
            group.addTask { await catcher.decide(offer) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch decision {
        case let .accept(fileName, totalBytes, start)?:
            let id = await start()
            caught.yield(CaughtDownload(id: id, link: offer.url, fileName: fileName, totalBytes: totalBytes, session: session.id))
            return .catchAccepted
        case let .decline(reason)?:
            return .catchDeclined(reason)
        case nil:
            return .catchDeclined(.error)
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

final class Session: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
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
