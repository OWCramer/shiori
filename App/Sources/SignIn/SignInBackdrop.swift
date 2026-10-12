#if os(iOS)
import SwiftUI

/// The sign-in screen's background, after Shiori's Hanafuda icon: dark lacquer red fading to
/// black, the icon's faint rings in the corners, and sakura petals drifting slowly down
/// (still with Reduce Motion). Drawn here, so nothing is fetched before signing in.
struct SignInBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.05, blue: 0.07), Color(red: 0.09, green: 0.02, blue: 0.04), .black],
                           startPoint: .top, endPoint: .bottom)
            SignInRings()
            if reduceMotion {
                SignInPetals(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    SignInPetals(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The icon's concentric rings, faint, in two corners.
private struct SignInRings: View {
    var body: some View {
        Canvas { context, size in
            let color = Color(red: 0.93, green: 0.80, blue: 0.62).opacity(0.07)
            for (centre, base) in [(CGPoint(x: size.width, y: 0), 120.0), (CGPoint(x: 0, y: size.height), 160.0)] {
                for ring in 0..<4 {
                    let radius = base + Double(ring) * 44
                    let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
                }
            }
        }
    }
}

/// Sakura petals falling and swaying, at `time` seconds.
private struct SignInPetals: View {
    let time: TimeInterval

    private static let count = 18

    var body: some View {
        Canvas { context, size in
            for index in 0..<Self.count {
                // Each petal's own speed, sway and place, from its index.
                let seed = Double(index) * 12.9898
                let random = { (salt: Double) in abs(sin(seed + salt) * 43758.5453).truncatingRemainder(dividingBy: 1) }
                let fall = 14 + random(1) * 18 // points a second
                let travel = size.height + 80
                let y = (random(2) * travel + time * fall).truncatingRemainder(dividingBy: travel) - 40
                let x = random(3) * size.width + sin(time * (0.3 + random(4) * 0.4) + seed) * 28
                let scale = 0.6 + random(5) * 0.8
                let angle = Angle.radians(time * (0.4 + random(6)) + seed)
                var petal = context
                petal.translateBy(x: x, y: y)
                petal.rotate(by: angle)
                petal.scaleBy(x: scale, y: scale)
                petal.opacity = 0.25 + random(7) * 0.35
                petal.fill(Self.petalPath, with: .color(Color(red: 0.98, green: 0.75, blue: 0.82)))
            }
        }
    }

    /// A petal: an oval notched at its tip.
    private static let petalPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -7))
        path.addQuadCurve(to: CGPoint(x: 0, y: 7), control: CGPoint(x: 9, y: -2))
        path.addQuadCurve(to: CGPoint(x: 0, y: -7), control: CGPoint(x: -9, y: -2))
        path.move(to: CGPoint(x: 0, y: -7))
        return path
    }()
}
#endif
