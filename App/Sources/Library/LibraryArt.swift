import Kingfisher
import SteamKit
import SwiftUI

/// A portrait capsule with the game's download state over it.
struct CapsuleCard: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsuleArt(game: game)
                .overlay(alignment: .bottom) { statusOverlay }
                .overlay(alignment: .topLeading) { engineBadge }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(game.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Before download: what the game runs on, from its manifests. Green when playable.
    @ViewBuilder private var engineBadge: some View {
        if status == .notInstalled, let scan = engineScans.result(for: game.appID), scan.error == nil {
            // A beta that plays (WORLD END ECONOMiCA's KiriKiri/Ren'Py originals) counts.
            let beta = Playability(scan.engine, appID: game.appID) == .playable ? nil : scan.playableBranch
            let playable = Playability(scan.engine, appID: game.appID) == .playable || beta != nil
            let label = beta.map { "\(Playability.badge($0.engine)) (beta)" } ?? Playability.badge(scan.engine, appID: game.appID)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playable ? Color.green.opacity(0.85) : Color.black.opacity(0.6), in: .capsule)
                .padding(6)
                .accessibilityLabel(playable ? "Playable, \(label)" : label)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch status {
        case .installed:
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .padding(6)
                    .accessibilityLabel("Downloaded")
            }
        case let .downloading(progress):
            ProgressView(value: progress.fraction)
                .tint(.white)
                .padding(8)
                .background(.black.opacity(0.45))
        case .preparing, .queued, .verifying:
            HStack {
                Spacer()
                Image(systemName: status == .queued ? "clock.fill" : "ellipsis.circle.fill")
                    .foregroundStyle(.white).font(.title3).padding(6)
            }
        case .paused:
            HStack {
                Spacer()
                Image(systemName: "pause.circle.fill").foregroundStyle(.white).font(.title3).padding(6)
                    .accessibilityLabel("Download paused")
            }
        case .failed:
            HStack {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.title3).padding(6)
            }
        case .notInstalled:
            EmptyView()
        }
    }
}

/// 600×900 library art, falling back to the landscape header, then to the name.
struct CapsuleArt: View {
    let game: LibraryGame

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                // Decoded at grid size, cached in memory and on disk (Kingfisher).
                KFImage(game.capsule)
                    .placeholder { Rectangle().fill(.fill.tertiary) }
                    .onFailureView { fallback }
                    .downsampling(size: CGSize(width: 400, height: 600))
                    .cacheOriginalImage()
                    .cancelOnDisappear(true)
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                KFImage(game.header)
                    .placeholder { EmptyView() }
                    .onFailureView { EmptyView() }
                    .downsampling(size: CGSize(width: 460, height: 215))
                    .resizable()
                    .scaledToFit()
                Text(game.name)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Landscape Steam header art (460×215), falling back to the hero.
struct HeaderArt: View {
    let game: LibraryGame

    var body: some View {
        RemoteImage(url: game.header, fallback: game.hero, downsample: CGSize(width: 460, height: 215)) {
            ArtworkPlaceholder(title: game.name)
        }
        .aspectRatio(460 / 215, contentMode: .fit)
    }
}

/// The game's logo, or its name when it has none (or the logo can't load).
struct GameLogo: View {
    let game: LibraryGame
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 110
    var alignment: Alignment = .center

    var body: some View {
        Group {
            if let logo = game.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: alignment) { title }
            } else {
                title
            }
        }
        .frame(maxWidth: maxWidth, alignment: alignment)
        .frame(height: maxHeight)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
        .accessibilityLabel(game.name)
    }

    private var title: some View {
        Text(game.name)
            .font(.largeTitle.weight(.heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// Design A's capsule: the art with its state on glass, an engine badge before download
/// (green when Shiori plays it), progress while downloading, a tick once downloaded.
struct ShowcaseCapsule: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    var cornerRadius: CGFloat = 14
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        CapsuleArt(game: game)
            .overlay(alignment: .bottom) { progress }
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .topTrailing) { stateIcon }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.black)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
    }

    /// Before download: what the game runs on, from its manifests.
    @ViewBuilder private var badge: some View {
        if status == .notInstalled, let scan = engineScans.result(for: game.appID), scan.error == nil {
            // A beta that plays (WORLD END ECONOMiCA's KiriKiri/Ren'Py originals) counts.
            let plays = Playability(scan.engine, appID: game.appID) == .playable
            let beta = plays ? nil : scan.playableBranch
            let label = beta.map { "\(Playability.badge($0.engine)) (beta)" } ?? Playability.badge(scan.engine, appID: game.appID)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassEffect(.regular.tint((plays || beta != nil) ? .green.opacity(0.55) : .black.opacity(0.3)), in: .capsule)
                .padding(6)
                .accessibilityLabel((plays || beta != nil) ? "Playable, \(label)" : label)
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.title3).padding(6)
                .accessibilityLabel("Downloaded")
        case .queued, .preparing, .verifying:
            stateGlyph(status == .queued ? "clock.fill" : "ellipsis", label: status == .queued ? "Queued" : "Working")
        case .paused:
            stateGlyph("pause.fill", label: "Download paused")
        case .failed:
            stateGlyph("exclamationmark", label: "Download failed", tint: .red)
        default:
            EmptyView()
        }
    }

    private func stateGlyph(_ symbol: String, label: String, tint: Color? = nil) -> some View {
        Image(systemName: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .padding(6)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.6)) } ?? .regular, in: .circle)
            .padding(4)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var progress: some View {
        switch status {
        case let .downloading(progress):
            bar(progress.fraction)
        case let .paused(progress?):
            bar(progress.fraction)
        case let .verifying(progress):
            bar(progress.fraction)
        default:
            EmptyView()
        }
    }

    private func bar(_ fraction: Double) -> some View {
        GlassProgressBar(fraction: fraction, tint: .white)
            .padding(8)
            .glassEffect(.regular, in: .capsule)
            .padding(6)
    }
}
