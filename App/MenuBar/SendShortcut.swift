import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let sendPage = Self("sendPage", default: .init(.d, modifiers: [.option, .shift]))
}

struct SendShortcutRecorder: View {
    var body: some View {
        LabeledContent {
            KeyboardShortcuts.Recorder(for: .sendPage)
        } label: {
            Text("Send to Dowlio")
            Text("Sends the page you're on in Chrome, Arc, Brave, Edge, Dia and other browsers with Dowlio Connect.")
        }
    }
}
