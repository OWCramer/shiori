#if DEBUG
import UIKit

/// Covers for the screenshot library (`-ShioriScreenshotLibrary`), drawn here in the language
/// of Shiori's Hanafuda icon: flat lacquer skies, a moon or sun, layered hills, a seasonal
/// motif and drifting petals. Nothing is fetched; nothing is anyone's game art.
enum ScreenshotArt {
    enum Motif { case sakura, plum, pine, maple, waves, stars, snow, lanterns, grass }

    struct Style {
        var sky: (UIColor, UIColor)
        var disc: UIColor
        var crescent = false
        var hills: [UIColor]
        var motif: Motif
        var accent: UIColor
        /// The title's colour on capsules and headers.
        var ink: UIColor = UIColor(red: 0.97, green: 0.92, blue: 0.80, alpha: 1)
    }

    enum Kind {
        case capsule, header, hero, logo

        var size: CGSize {
            switch self {
            case .capsule: CGSize(width: 600, height: 900)
            case .header: CGSize(width: 920, height: 430)
            case .hero: CGSize(width: 1920, height: 620)
            case .logo: CGSize(width: 1280, height: 480)
            }
        }
    }

    static func png(_ kind: Kind, title: String, style: Style, seed: UInt32) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = kind != .logo
        let renderer = UIGraphicsImageRenderer(size: kind.size, format: format)
        return renderer.pngData { context in
            let cg = context.cgContext
            let bounds = CGRect(origin: .zero, size: kind.size)
            var random = SeededRandom(seed: UInt64(seed))
            switch kind {
            case .logo:
                drawTitle(title, in: bounds.insetBy(dx: 40, dy: 30), size: 132, style: style, shadow: true, cg: cg)
            case .hero:
                drawScene(in: bounds, style: style, random: &random, cg: cg)
            case .header:
                drawScene(in: bounds, style: style, random: &random, cg: cg)
                let band = CGRect(x: 0, y: bounds.height * 0.52, width: bounds.width * 0.72, height: bounds.height * 0.44)
                drawTitle(title, in: band.insetBy(dx: 36, dy: 8), size: 58, style: style, shadow: true, cg: cg, alignment: .left)
            case .capsule:
                // A Hanafuda card: a cream border around the picture, the title on the dark ground.
                UIColor(red: 0.95, green: 0.89, blue: 0.76, alpha: 1).setFill()
                cg.fill(bounds)
                let inner = bounds.insetBy(dx: 26, dy: 26)
                cg.saveGState()
                cg.addPath(UIBezierPath(roundedRect: inner, cornerRadius: 18).cgPath)
                cg.clip()
                drawScene(in: inner, style: style, random: &random, cg: cg)
                let band = CGRect(x: inner.minX, y: inner.maxY - inner.height * 0.3, width: inner.width, height: inner.height * 0.3)
                // The ground darkens under the title, so it reads over any motif.
                let ground = (style.hills.last ?? .black).withAlphaComponent(0.9)
                if let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [ground.withAlphaComponent(0).cgColor, ground.cgColor] as CFArray, locations: [0, 0.45]) {
                    cg.drawLinearGradient(shade, start: CGPoint(x: band.midX, y: band.minY - 40), end: CGPoint(x: band.midX, y: band.maxY), options: [])
                }
                drawTitle(title, in: band.insetBy(dx: 30, dy: 24), size: 64, style: style, shadow: true, cg: cg)
                cg.restoreGState()
            }
        }
    }

    // MARK: Scene

    private static func drawScene(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        cg.saveGState()
        cg.clip(to: rect)
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: [style.sky.0.cgColor, style.sky.1.cgColor] as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        let short = min(rect.width, rect.height)
        let tall = rect.height > rect.width

        // Faint rings, as on the icon's backdrop.
        style.ink.withAlphaComponent(0.08).setStroke()
        cg.setLineWidth(max(2, short * 0.006))
        let ringCentre = random.bool() ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.minY)
        for ring in 0..<4 {
            let radius = short * (0.28 + CGFloat(ring) * 0.09)
            cg.strokeEllipse(in: CGRect(x: ringCentre.x - radius, y: ringCentre.y - radius, width: radius * 2, height: radius * 2))
        }

        if style.motif == .stars { drawStars(in: rect, random: &random, cg: cg) }

        // The moon (or sun).
        let radius = short * (tall ? 0.27 : 0.3)
        let centre = CGPoint(x: rect.minX + rect.width * random.within(tall ? 0.38...0.62 : rect.width > rect.height * 2.5 ? 0.5...0.58 : 0.55...0.78),
                             y: rect.minY + rect.height * (tall ? random.within(0.26...0.34) : random.within(0.34...0.46)))
        let discRect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        cg.saveGState()
        if style.crescent {
            cg.addRect(rect)
            cg.addEllipse(in: discRect.offsetBy(dx: radius * 0.42, dy: -radius * 0.18))
            cg.clip(using: .evenOdd)
        }
        style.disc.withAlphaComponent(0.25).setFill()
        cg.fillEllipse(in: discRect.insetBy(dx: -radius * 0.08, dy: -radius * 0.08))
        style.disc.setFill()
        cg.fillEllipse(in: discRect)
        cg.restoreGState()

        if style.motif == .lanterns { drawLanterns(in: rect, style: style, random: &random, cg: cg) }

        // Hills, back to front.
        let layers = style.hills.count
        for (index, colour) in style.hills.enumerated() {
            let top = rect.minY + rect.height * (0.6 + CGFloat(index) / CGFloat(max(layers, 1)) * 0.2)
            drawHill(in: rect, top: top, amplitude: rect.height * random.within(0.03...0.07), phase: random.within(0...6), colour: colour, cg: cg)
            if index == 0, style.motif == .pine { drawPines(in: rect, base: top, random: &random, cg: cg, colour: colour) }
            if index == 0, style.motif == .snow { drawSnowcaps(in: rect, base: top, cg: cg) }
        }

        switch style.motif {
        case .sakura, .plum: drawBranch(in: rect, style: style, random: &random, cg: cg)
        case .maple: drawLeaves(in: rect, style: style, random: &random, cg: cg)
        case .waves: drawWaves(in: rect, style: style, cg: cg)
        case .grass: drawGrass(in: rect, style: style, random: &random, cg: cg)
        case .snow: drawSnowfall(in: rect, random: &random, cg: cg)
        default: break
        }
        drawPetals(in: rect, style: style, random: &random, cg: cg)
        cg.restoreGState()
    }

    private static func drawHill(in rect: CGRect, top: CGFloat, amplitude: CGFloat, phase: CGFloat, colour: UIColor, cg: CGContext) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let steps = 48
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = rect.minX + rect.width * t
            let y = top + sin(t * .pi * 2.2 + phase) * amplitude + sin(t * .pi * 5 + phase * 2) * amplitude * 0.3
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        colour.setFill()
        path.fill()
    }

    private static func drawBranch(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        let start = CGPoint(x: rect.minX - short * 0.05, y: rect.minY + rect.height * random.within(0.42...0.52))
        let end = CGPoint(x: rect.maxX + short * 0.02, y: rect.minY + rect.height * random.within(0.2...0.3))
        let control = CGPoint(x: rect.midX, y: (start.y + end.y) / 2 + short * 0.08)
        let branch = UIBezierPath()
        branch.move(to: start)
        branch.addQuadCurve(to: end, controlPoint: control)
        UIColor(red: 0.17, green: 0.09, blue: 0.08, alpha: 1).setStroke()
        branch.lineWidth = short * 0.03
        branch.lineCapStyle = .round
        branch.stroke()
        let twig = UIBezierPath()
        let mid = point(onQuad: start, control, end, t: 0.45)
        twig.move(to: mid)
        twig.addQuadCurve(to: CGPoint(x: mid.x + short * 0.18, y: mid.y - short * 0.16), controlPoint: CGPoint(x: mid.x + short * 0.02, y: mid.y - short * 0.14))
        twig.lineWidth = short * 0.016
        twig.lineCapStyle = .round
        twig.stroke()
        for t in stride(from: 0.18, through: 0.9, by: 0.18) {
            let p = point(onQuad: start, control, end, t: CGFloat(t) + random.within(-0.04...0.04))
            drawBlossom(at: CGPoint(x: p.x, y: p.y + random.within(-0.03...0.03) * short), radius: short * random.within(0.045...0.065),
                        petal: style.accent, heart: style.motif == .plum ? UIColor(red: 0.98, green: 0.86, blue: 0.4, alpha: 1)
                                                                          : UIColor(red: 0.85, green: 0.3, blue: 0.45, alpha: 1), cg: cg)
        }
        drawBlossom(at: CGPoint(x: mid.x + short * 0.18, y: mid.y - short * 0.16), radius: short * 0.05, petal: style.accent,
                    heart: UIColor(red: 0.85, green: 0.3, blue: 0.45, alpha: 1), cg: cg)
    }

    private static func point(onQuad a: CGPoint, _ c: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private static func drawBlossom(at centre: CGPoint, radius: CGFloat, petal: UIColor, heart: UIColor, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: centre.x, y: centre.y)
        petal.setFill()
        for index in 0..<5 {
            cg.saveGState()
            cg.rotate(by: CGFloat(index) * .pi * 2 / 5)
            cg.fillEllipse(in: CGRect(x: -radius * 0.42, y: -radius * 1.05, width: radius * 0.84, height: radius * 1.05))
            cg.restoreGState()
        }
        heart.setFill()
        cg.fillEllipse(in: CGRect(x: -radius * 0.22, y: -radius * 0.22, width: radius * 0.44, height: radius * 0.44))
        cg.restoreGState()
    }

    private static func drawPetals(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        guard [.sakura, .plum, .lanterns, .grass, .waves].contains(style.motif) else { return }
        let short = min(rect.width, rect.height)
        for _ in 0..<9 {
            let p = CGPoint(x: rect.minX + rect.width * random.within(0...1), y: rect.minY + rect.height * random.within(0.05...0.95))
            cg.saveGState()
            cg.translateBy(x: p.x, y: p.y)
            cg.rotate(by: random.within(0...(.pi * 2)))
            style.accent.withAlphaComponent(random.within(0.45...0.85)).setFill()
            let size = short * random.within(0.014...0.026)
            cg.fillEllipse(in: CGRect(x: -size, y: -size * 0.6, width: size * 2, height: size * 1.2))
            cg.restoreGState()
        }
    }

    private static func drawPines(in rect: CGRect, base: CGFloat, random: inout SeededRandom, cg: CGContext, colour: UIColor) {
        let short = min(rect.width, rect.height)
        colour.setFill()
        for _ in 0..<3 {
            let x = rect.minX + rect.width * random.within(0.05...0.95)
            let height = short * random.within(0.22...0.34)
            for tier in 0..<4 {
                let width = height * (0.7 - CGFloat(tier) * 0.13)
                let y = base - height * CGFloat(tier) * 0.24
                let path = UIBezierPath()
                path.move(to: CGPoint(x: x - width / 2, y: y + 4))
                path.addQuadCurve(to: CGPoint(x: x + width / 2, y: y + 4), controlPoint: CGPoint(x: x, y: y - height * 0.3))
                path.close()
                path.fill()
            }
        }
    }

    private static func drawSnowcaps(in rect: CGRect, base: CGFloat, cg: CGContext) {
        let path = UIBezierPath()
        let peak = CGPoint(x: rect.minX + rect.width * 0.3, y: base - rect.height * 0.22)
        path.move(to: CGPoint(x: peak.x - rect.width * 0.08, y: peak.y + rect.height * 0.08))
        path.addLine(to: peak)
        path.addLine(to: CGPoint(x: peak.x + rect.width * 0.08, y: peak.y + rect.height * 0.08))
        path.addQuadCurve(to: CGPoint(x: peak.x - rect.width * 0.08, y: peak.y + rect.height * 0.08),
                          controlPoint: CGPoint(x: peak.x, y: peak.y + rect.height * 0.04))
        let mountain = UIBezierPath()
        mountain.move(to: CGPoint(x: peak.x - rect.width * 0.35, y: base + 10))
        mountain.addLine(to: peak)
        mountain.addLine(to: CGPoint(x: peak.x + rect.width * 0.35, y: base + 10))
        mountain.close()
        UIColor(red: 0.28, green: 0.33, blue: 0.45, alpha: 1).setFill()
        mountain.fill()
        UIColor(white: 0.97, alpha: 1).setFill()
        path.fill()
    }

    private static func drawSnowfall(in rect: CGRect, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        for _ in 0..<70 {
            let size = short * random.within(0.004...0.012)
            UIColor(white: 1, alpha: random.within(0.5...0.95)).setFill()
            cg.fillEllipse(in: CGRect(x: rect.minX + rect.width * random.within(0...1), y: rect.minY + rect.height * random.within(0...1), width: size, height: size))
        }
    }

    private static func drawStars(in rect: CGRect, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        for index in 0..<60 {
            let p = CGPoint(x: rect.minX + rect.width * random.within(0...1), y: rect.minY + rect.height * random.within(0...0.6))
            UIColor(white: 1, alpha: random.within(0.4...0.9)).setFill()
            if index % 12 == 0 {
                let s = short * 0.02
                let star = UIBezierPath()
                star.move(to: CGPoint(x: p.x, y: p.y - s))
                star.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), controlPoint: p)
                star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), controlPoint: p)
                star.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), controlPoint: p)
                star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), controlPoint: p)
                star.fill()
            } else {
                let size = short * random.within(0.003...0.008)
                cg.fillEllipse(in: CGRect(x: p.x, y: p.y, width: size, height: size))
            }
        }
    }

    private static func drawLanterns(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        let y0 = rect.minY + rect.height * 0.12
        let string = UIBezierPath()
        string.move(to: CGPoint(x: rect.minX, y: y0))
        string.addQuadCurve(to: CGPoint(x: rect.maxX, y: y0 - short * 0.03), controlPoint: CGPoint(x: rect.midX, y: y0 + short * 0.12))
        UIColor(white: 0.1, alpha: 0.8).setStroke()
        string.lineWidth = max(2, short * 0.005)
        string.stroke()
        let count = rect.width > rect.height * 2 ? 9 : 5
        for index in 0..<count {
            let t = (CGFloat(index) + 0.5) / CGFloat(count)
            let anchor = point(onQuad: CGPoint(x: rect.minX, y: y0), CGPoint(x: rect.midX, y: y0 + short * 0.12),
                               CGPoint(x: rect.maxX, y: y0 - short * 0.03), t: t)
            let w = short * random.within(0.07...0.09), h = w * 1.3
            let body = CGRect(x: anchor.x - w / 2, y: anchor.y + short * 0.015, width: w, height: h)
            style.accent.withAlphaComponent(0.3).setFill()
            cg.fillEllipse(in: body.insetBy(dx: -w * 0.35, dy: -w * 0.35))
            style.accent.setFill()
            UIBezierPath(roundedRect: body, cornerRadius: w * 0.4).fill()
            UIColor(white: 0.1, alpha: 0.85).setFill()
            cg.fill(CGRect(x: body.minX + w * 0.15, y: body.minY - w * 0.08, width: w * 0.7, height: w * 0.12))
            cg.fill(CGRect(x: body.minX + w * 0.15, y: body.maxY - w * 0.04, width: w * 0.7, height: w * 0.12))
        }
    }

    private static func drawLeaves(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        for _ in 0..<12 {
            let centre = CGPoint(x: rect.minX + rect.width * random.within(0...1), y: rect.minY + rect.height * random.within(0.05...0.9))
            let r = short * random.within(0.03...0.06)
            cg.saveGState()
            cg.translateBy(x: centre.x, y: centre.y)
            cg.rotate(by: random.within(0...(.pi * 2)))
            let leaf = UIBezierPath()
            for point in 0..<10 {
                let angle = CGFloat(point) * .pi / 5 - .pi / 2
                let length = point.isMultiple(of: 2) ? r : r * 0.45
                let p = CGPoint(x: cos(angle) * length, y: sin(angle) * length)
                if point == 0 { leaf.move(to: p) } else { leaf.addLine(to: p) }
            }
            leaf.close()
            (random.bool() ? style.accent : style.accent.withAlphaComponent(0.75)).setFill()
            leaf.fill()
            cg.restoreGState()
        }
    }

    private static func drawWaves(in rect: CGRect, style: Style, cg: CGContext) {
        // Seigaiha: rows of concentric arcs across the foot of the picture.
        let short = min(rect.width, rect.height)
        let radius = short * 0.09
        let top = rect.minY + rect.height * 0.72
        var row = 0
        var y = top
        while y < rect.maxY + radius {
            let offset = row.isMultiple(of: 2) ? 0 : radius
            var x = rect.minX - radius + offset
            while x < rect.maxX + radius {
                for ring in 0..<4 {
                    let r = radius * (1 - CGFloat(ring) * 0.24)
                    (ring.isMultiple(of: 2) ? style.hills.last ?? .black : style.accent).setFill()
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                x += radius * 2
            }
            y += radius * 0.6
            row += 1
        }
    }

    private static func drawGrass(in rect: CGRect, style: Style, random: inout SeededRandom, cg: CGContext) {
        let short = min(rect.width, rect.height)
        UIColor(red: 0.12, green: 0.1, blue: 0.08, alpha: 0.9).setStroke()
        for _ in 0..<26 {
            let x = rect.minX + rect.width * random.within(0...1)
            let blade = UIBezierPath()
            blade.move(to: CGPoint(x: x, y: rect.maxY))
            let height = rect.height * random.within(0.18...0.4)
            blade.addQuadCurve(to: CGPoint(x: x + short * random.within(-0.12...0.12), y: rect.maxY - height),
                               controlPoint: CGPoint(x: x, y: rect.maxY - height * 0.6))
            blade.lineWidth = short * random.within(0.004...0.009)
            blade.lineCapStyle = .round
            blade.stroke()
        }
    }

    // MARK: Title

    private static func drawTitle(_ title: String, in rect: CGRect, size: CGFloat, style: Style, shadow: Bool, cg: CGContext,
                                  alignment: NSTextAlignment = .center) {
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.92
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.ink, .paragraphStyle: paragraph]
        if shadow {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = size * 0.12
            shadow.shadowOffset = CGSize(width: 0, height: size * 0.04)
            attributes[.shadow] = shadow
        }
        // Shrink until it fits.
        var text = NSAttributedString(string: title, attributes: attributes)
        var scale: CGFloat = 1
        while scale > 0.4 {
            let bounds = text.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if bounds.height <= rect.height { break }
            scale -= 0.06
            attributes[.font] = font.withSize(size * scale)
            text = NSAttributedString(string: title, attributes: attributes)
        }
        let height = text.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        text.draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}

/// SplitMix64: the same picture for the same title on every run.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func within(_ range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(next() % 1_000_000) / 1_000_000
    }

    mutating func bool() -> Bool { next() % 2 == 0 }
}
#endif
