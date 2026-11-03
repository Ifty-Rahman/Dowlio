import AppKit
import DowlioConnect

@MainActor
final class PairingAlert: NSObject {
    private static var showing: Set<PairingAlert> = []

    private let alert = NSAlert()
    private var answer: CheckedContinuation<Bool, Never>?
    private var isClosed = false

    static func show(_ request: PairingRequest) async -> Bool {
        let prompt = PairingAlert(request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in prompt.present(answering: continuation) }
        } onCancel: {
            Task { @MainActor in prompt.close(returning: true) }
        }
    }

    private init(_ request: PairingRequest) {
        super.init()
        alert.messageText = "Type \(Self.spaced(request.code)) in Dowlio Connect"
        alert.informativeText = request.isIdentified
            ? "\(request.browser) wants to connect to Dowlio. Open the Dowlio Connect popup in \(request.browser) and type this code. Downloads from that browser can then finish in Dowlio."
            : "An app Dowlio couldn't identify wants to connect to Dowlio. It says it's \(request.browser). Type this code only in the Dowlio Connect popup of a browser you just added it to."
        let dontAllow = alert.addButton(withTitle: "Don't Allow")
        dontAllow.target = self
        dontAllow.action = #selector(refuse)
    }

    private func present(answering continuation: CheckedContinuation<Bool, Never>) {
        guard !isClosed else { return continuation.resume(returning: true) }
        answer = continuation
        Self.showing.insert(self)
        alert.layout()
        let window = alert.window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.center()
        window.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    @objc private func refuse() {
        close(returning: false)
    }

    private func close(returning stillAllowed: Bool) {
        guard !isClosed else { return }
        isClosed = true
        alert.window.orderOut(nil)
        Self.showing.remove(self)
        answer?.resume(returning: stillAllowed)
        answer = nil
    }

    private static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
