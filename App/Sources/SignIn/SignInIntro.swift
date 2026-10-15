// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Who Shiori is and what it does: the Hanafuda card, the name with 栞 (bookmark), a line,
/// and three things it does with your Steam library.
struct SignInIntro: View {
    let alignment: HorizontalAlignment
    var showsFeatures = true

    var body: some View {
        VStack(alignment: alignment, spacing: 18) {
            Image(.hanafudaCard)
                .resizable()
                .scaledToFit()
                .frame(width: 110)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: alignment, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Shiori").font(.largeTitle).bold()
                    Text("栞")
                        .font(.title)
                        .foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.82))
                        .accessibilityLabel("bookmark, in Japanese")
                }
                Text("The visual novels you own on Steam, on your \(UIDevice.current.localizedModel).")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .center)
            }
            if showsFeatures {
            VStack(alignment: .leading, spacing: 12) {
                SignInFeature(systemImage: "arrow.down.circle", text: "Downloads your games straight from Steam.")
                SignInFeature(systemImage: "play.circle", text: "Plays them here: Ren'Py, KiriKiri, Artemis and more.")
                SignInFeature(systemImage: "icloud", text: "Keeps your saves with Steam Cloud and iCloud.")
            }
            .frame(maxWidth: 380, alignment: .leading)
            }
        }
    }
}

/// One thing Shiori does.
private struct SignInFeature: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color(red: 0.98, green: 0.75, blue: 0.82))
        }
        .font(.callout)
    }
}
#endif
