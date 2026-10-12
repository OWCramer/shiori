import SwiftUI

/// A button whose label doesn't change while pressed: for large art that just opens a page
/// (Home's hero), where `.plain`'s dimming reads as the picture flickering.
struct NoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(.rect)
    }
}
