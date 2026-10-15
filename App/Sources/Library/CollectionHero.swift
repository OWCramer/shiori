// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The top of a collection's page, as a game page's: its first game's banner, the
/// collection's name on it, and below, extended from the art, its count and size and
/// Download All.
struct CollectionHero: View {
    let collection: LibraryCollection
    /// The game whose art leads (the first released).
    let lead: LibraryGame
    /// The collection a sub-group is in, named over its title.
    let parentName: String?
    let summary: CollectionSummary
    let bannerHeight: CGFloat
    var overscroll: CGFloat = 0
    let wide: Bool
    /// Opened on part of the collection: what the header says of it ("3 of 6 downloaded"),
    /// how many games the whole has, and the way to show them all.
    var scoped: (line: String, total: Int, showAll: () -> Void)?
    let downloadAll: () -> Void
    @Environment(SteamModel.self) private var steam
    @State private var extensionHeight: CGFloat = 150

    private var metaLine: String {
        if let scoped {
            return ([scoped.line] + (summary.totalSize > 0 ? [summary.totalSize.formatted(.byteCount(style: .file))] : []))
                .joined(separator: " · ")
        }
        var parts = [summary.gamesText]
        if summary.downloading > 0 {
            parts.append("\(summary.downloading) downloading")
        } else if summary.downloaded > 0 {
            parts.append(summary.downloaded == summary.total ? "All downloaded" : "\(summary.downloaded) downloaded")
        }
        if summary.totalSize > 0 { parts.append(summary.totalSize.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let alignment: HorizontalAlignment = wide ? .leading : .center
        VStack(spacing: 0) {
            VStack(alignment: alignment, spacing: 4) {
                Text(parentName.map { "\($0) · Collection" } ?? "Collection")
                    .font(.subheadline.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.8))
                Text(collection.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(wide ? .leading : .center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .shadow(color: .black.opacity(0.6), radius: 8)
            .frame(maxWidth: .infinity, alignment: wide ? .bottomLeading : .bottom)
            .padding(.bottom, 20)
            .frame(height: bannerHeight, alignment: .bottom)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: alignment, spacing: 14) {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                Group {
                    if let scoped {
                        Button(action: scoped.showAll) {
                            GameActionLabel(title: "Show All \(scoped.total) Games", systemImage: "square.stack", iconOnly: false)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: wide ? nil : .infinity)
                        }
                        .buttonStyle(.glass)
                    } else {
                        downloadButton
                    }
                }
                .controlSize(.large)
                if scoped == nil, !summary.toDownload.isEmpty, let reason = steam.offlineReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { extensionHeight = $0 }
        }
        .frame(maxWidth: wide ? GamePageMetrics.wideContentWidth : GamePageMetrics.readableWidth)
        .padding(.horizontal, wide ? GamePageMetrics.wideMargin : GamePageMetrics.margin)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ExtendedHeroArt(game: lead, bannerHeight: bannerHeight, extensionHeight: extensionHeight, overscroll: overscroll)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var downloadButton: some View {
        if summary.toDownload.isEmpty {
            Button {} label: {
                GameActionLabel(title: summary.downloading > 0 ? "Downloading" : "All Downloaded",
                                systemImage: summary.downloading > 0 ? "arrow.down.circle" : "checkmark.circle", iconOnly: false)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: wide ? nil : .infinity)
            }
            .buttonStyle(.glass)
            .disabled(true)
        } else {
            Button(action: downloadAll) {
                GameActionLabel(title: "Download All", systemImage: "arrow.down.circle.fill", iconOnly: false)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: wide ? nil : .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(!steam.isLoggedOn)
        }
    }
}
#endif
