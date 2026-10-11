import SwiftUI

/// A game's name set like a logo, for games without one.
struct GameLogoTitle: View {
    let name: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        Text(name)
            .font(.largeTitle)
            .bold()
            .foregroundStyle(.white)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
    }
}
