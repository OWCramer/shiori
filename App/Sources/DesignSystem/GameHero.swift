// Hero, backdrop and glass building blocks for game pages, after the user's Tana app
// (Tana/DesignSystem: GameHeroHeader, StretchyHeader, GlassComponents, RemoteImage).

import SwiftUI

/// Loads remote artwork into whatever frame it's given, trying each URL in turn.
///
/// Size-neutral on purpose: a bare `.resizable().scaledToFill()` image reports an ideal
/// size from the artwork's proportions, which can widen every ancestor. Rendering into
/// a `Color.clear` container makes that impossible.
struct RemoteImage<Placeholder: View>: View {
    var urls: [URL]
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    @ViewBuilder var placeholder: Placeholder

    init(url: URL?, fallback: URL? = nil, contentMode: ContentMode = .fill, alignment: Alignment = .center,
         @ViewBuilder placeholder: () -> Placeholder) {
        urls = [url, fallback].compactMap { $0 }
        self.contentMode = contentMode
        self.alignment = alignment
        self.placeholder = placeholder()
    }

    var body: some View {
        Color.clear
            .overlay(alignment: alignment) { image(at: 0) }
            .clipped()
    }

    private func image(at index: Int) -> AnyView {
        guard index < urls.count else { return AnyView(placeholder) }
        return AnyView(AsyncImage(url: urls[index], transaction: Transaction(animation: .smooth(duration: 0.25))) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            case .failure:
                self.image(at: index + 1)
            default:
                placeholder
            }
        })
    }
}

/// A hero image welded to the top of the screen that grows when the scroll view is
/// pulled past its top. The enclosing scroll view reports the overscroll through
/// `scrollOverscroll(_:)`; reading the header's own geometry doesn't work, because the
/// scroll view's content space always puts the topmost child at zero.
struct StretchyHeader<Content: View>: View {
    var height: CGFloat
    var overscroll: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity)
                    .frame(height: height + max(0, overscroll))
                    .clipped()
            }
    }
}

extension View {
    /// Reports how far this scroll view is pulled past its top edge (0 at rest).
    func scrollOverscroll(_ overscroll: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            let pulled = max(0, -offset)
            if overscroll.wrappedValue != pulled { overscroll.wrappedValue = pulled }
        }
    }
}

/// Key art with the game's logo and a metadata line centred over it, ramping into the
/// page background.
struct GameHeroHeader: View {
    var game: LibraryGame
    var subtitle: String
    var height: CGFloat = 400
    var overscroll: CGFloat = 0

    var body: some View {
        StretchyHeader(height: height, overscroll: overscroll) {
            RemoteImage(url: game.hero, fallback: game.header) { ArtworkPlaceholder(title: game.name) }
        }
        .overlay(alignment: .bottom) {
            // A tall, gentle ramp; a short steep fade reads as a blurred band.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.55),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 240)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { titleTreatment }
    }

    private var titleTreatment: some View {
        VStack(spacing: 10) {
            if let logo = game.logo {
                RemoteImage(url: logo, contentMode: .fit) { title }
                    .frame(maxWidth: 280, maxHeight: 96)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            } else {
                title
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var title: some View {
        Text(game.name)
            .font(.largeTitle.weight(.heavy))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Near-black, tinted by the artwork behind it, so the key art carries the page.
struct GameBackdrop: View {
    var game: LibraryGame

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: game.hero, fallback: game.capsule) { Color.black }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 80, opaque: true)
                .saturation(1.6)
                .opacity(0.35)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Initials over a gradient derived from the title, for games without art.
struct ArtworkPlaceholder: View {
    var title: String

    var body: some View {
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.45), Color(hue: hue + 0.08, saturation: 0.6, brightness: 0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

struct GlassChip: View {
    var title: String
    var systemImage: String?
    var tint: Color = .secondary

    init(_ title: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(tint.opacity(0.16)), in: .capsule)
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(height: 22, alignment: .leading)
            Text(value)
                .font(.title2.weight(.bold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct GlassProgressBar: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 8)
        .animation(.smooth, value: fraction)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// A titled block on a game page.
struct GameSection<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

extension View {
    /// The rounded glass card the game page puts each section's content on.
    func glassCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
