#!/usr/bin/env swift
// Draws Shiori's app icon (1024×1024 PNG): a vermilion bookmark ribbon (栞, shiori) with a
// sakura blossom, on a night-indigo sky. Run: swift Scripts/make-app-icon.swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward, like a design canvas.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// Sky: deep indigo at the top, warming to plum at the bottom.
let sky = CGGradient(colorsSpace: space, colors: [rgb(0x151033), rgb(0x2A1B57), rgb(0x5A2A6A)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: size / 2, y: 0), end: CGPoint(x: size / 2, y: size), options: [])

// A soft moon glow behind the ribbon.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFE7C2, 0.38), rgb(0xFFE7C2, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 430), endRadius: 430, options: [])

// Faint stars.
var seed: UInt64 = 0x5EED
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
for _ in 0 ..< 46 {
    let x = random() * size, y = random() * size * 0.62, r = 1.5 + random() * 3.5
    ctx.setFillColor(rgb(0xFFFFFF, 0.25 + random() * 0.45))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// The bookmark: a tall ribbon with a swallowtail notch, slightly tilted.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -0.10)
let w: CGFloat = 250, top: CGFloat = -330, bottom: CGFloat = 360, notch: CGFloat = 120
let ribbon = CGMutablePath()
ribbon.move(to: CGPoint(x: -w / 2, y: top + 36))
ribbon.addQuadCurve(to: CGPoint(x: -w / 2 + 36, y: top), control: CGPoint(x: -w / 2, y: top))
ribbon.addLine(to: CGPoint(x: w / 2 - 36, y: top))
ribbon.addQuadCurve(to: CGPoint(x: w / 2, y: top + 36), control: CGPoint(x: w / 2, y: top))
ribbon.addLine(to: CGPoint(x: w / 2, y: bottom))
ribbon.addLine(to: CGPoint(x: 0, y: bottom - notch))
ribbon.addLine(to: CGPoint(x: -w / 2, y: bottom))
ribbon.closeSubpath()

// Shadow, then a silk-like vermilion gradient across the ribbon.
ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 48, color: rgb(0x07041A, 0.55))
ctx.addPath(ribbon)
ctx.setFillColor(rgb(0xD8392B))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(ribbon)
ctx.clip()
let silk = CGGradient(colorsSpace: space, colors: [rgb(0xB82A22), rgb(0xF0573F), rgb(0xE5452F), rgb(0xA92420)] as CFArray,
                      locations: [0, 0.38, 0.62, 1])!
ctx.drawLinearGradient(silk, start: CGPoint(x: -w / 2, y: 0), end: CGPoint(x: w / 2, y: 0), options: [])
// Two thin gold threads down the ribbon.
ctx.setStrokeColor(rgb(0xF3C77A, 0.85))
ctx.setLineWidth(7)
for x in [-w / 2 + 30, w / 2 - 30] {
    ctx.move(to: CGPoint(x: x, y: top + 20))
    ctx.addLine(to: CGPoint(x: x, y: bottom))
}
ctx.strokePath()
ctx.restoreGState()

// The cord loop above the ribbon, gold.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -0.10)
ctx.setStrokeColor(rgb(0xF3C77A))
ctx.setLineWidth(12)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: -26, y: top + 4))
ctx.addCurve(to: CGPoint(x: 26, y: top + 4), control1: CGPoint(x: -110, y: top - 150), control2: CGPoint(x: 110, y: top - 150))
ctx.strokePath()
ctx.restoreGState()

// A sakura blossom resting on the ribbon.
func blossom(center: CGPoint, radius r: CGFloat, rotation: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotation)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x3A0A1E, 0.45))
    for i in 0 ..< 5 {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(i) * 2 * .pi / 5)
        // A petal: rounded, with the cherry blossom's notch at its tip.
        let petal = CGMutablePath()
        petal.move(to: .zero)
        petal.addCurve(to: CGPoint(x: -r * 0.17, y: -r), control1: CGPoint(x: -r * 0.62, y: -r * 0.32), control2: CGPoint(x: -r * 0.58, y: -r * 0.98))
        petal.addLine(to: CGPoint(x: 0, y: -r * 0.84))
        petal.addLine(to: CGPoint(x: r * 0.17, y: -r))
        petal.addCurve(to: .zero, control1: CGPoint(x: r * 0.58, y: -r * 0.98), control2: CGPoint(x: r * 0.62, y: -r * 0.32))
        ctx.addPath(petal)
        ctx.setFillColor(rgb(0xFBD3DF))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Deeper pink toward the heart of the flower.
    let heart = CGGradient(colorsSpace: space, colors: [rgb(0xE9789A, 0.95), rgb(0xF5A9C0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(heart, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 0.55, options: [])
    // Stamens.
    ctx.setFillColor(rgb(0xF6C35C))
    for i in 0 ..< 10 {
        let a = CGFloat(i) * 2 * .pi / 10 + 0.2
        let d = r * (i % 2 == 0 ? 0.22 : 0.15)
        ctx.fillEllipse(in: CGRect(x: cos(a) * d - 9, y: sin(a) * d - 9, width: 18, height: 18))
    }
    ctx.restoreGState()
}
blossom(center: CGPoint(x: 600, y: 318), radius: 168, rotation: 0.25)
// A falling petal for movement.
ctx.saveGState()
ctx.translateBy(x: 300, y: 720)
ctx.rotate(by: -0.7)
ctx.setFillColor(rgb(0xFBD3DF, 0.9))
ctx.fillEllipse(in: CGRect(x: -26, y: -40, width: 52, height: 80))
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
