import AppKit
import DowlioConnect

@MainActor
enum PairingAlert {
    static func ask(_ request: PairingRequest) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Dowlio Connect in \(request.browser) wants to connect. Code \(request.code). Allow?"
        alert.informativeText = "Allow it only if the Dowlio Connect button in your browser shows the same code. Downloads from that browser can then finish in Dowlio."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
