import AppKit
import SwiftUI

extension View {
    func selectionBackground(_ isSelected: Bool) -> some View {
        background {
            if isSelected {
                RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
    }
}
