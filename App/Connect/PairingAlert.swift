import AppKit
import DowlioConnect

@MainActor
enum PairingAlert {
    static func show(_ request: PairingRequest) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Type \(spaced(request.code)) in Dowlio Connect"
        alert.informativeText = request.isIdentified
            ? "\(request.browser) wants to connect to Dowlio. Open the Dowlio Connect popup in \(request.browser) and type this code. Downloads from that browser can then finish in Dowlio."
            : "An app Dowlio couldn't identify wants to connect to Dowlio. It says it's \(request.browser). Type this code only in the Dowlio Connect popup of a browser you just added it to."
        alert.addButton(withTitle: "Don't Allow")
        let window = alert.window
        return await withTaskCancellationHandler {
            alert.runModal() != .alertFirstButtonReturn
        } onCancel: {
            Task { @MainActor in
                guard NSApp.modalWindow === window else { return }
                NSApp.stopModal(withCode: .abort)
            }
        }
    }

    private static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
