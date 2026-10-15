// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// "What's New in Shiori", as Apple's apps show it after an update: the title, a few
/// features with their symbols, and Continue. From Settings › About it's the same page
/// without Continue.
struct WhatsNewView: View {
    let release: WhatsNewRelease
    /// Shown after an update; nil when opened from Settings.
    var onContinue: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                VStack(spacing: 6) {
                    Text("What's New in Shiori")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Version \(release.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, onContinue == nil ? 16 : 56)
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(release.features, id: \.self) { feature in
                        WhatsNewFeatureRow(feature: feature)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.pink)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                // Solid under the buttons, fading out above them, so the list scrolls away beneath.
                .background {
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black, location: 0.3)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -24)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(Color.black)
    }
}
#endif
