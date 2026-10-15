#!/usr/bin/env swift
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

// Renders Shiori's app icon, "Hanafuda": a card with the full moon and a sakura branch on
// lacquer red, drawn from the SVG sources in Design/AppIcon (defs.svgfrag plus one *.body
// per picture). Run from the repo root: swift Scripts/make-app-icon.swift
//
// Writes the App Store icon (1024, opaque) into the asset catalog, the iOS layers for Icon
// Composer, and the tvOS parallax layers at 400×240, 800×480 and 1280×768 into
// Design/AppIcon/export.
import AppKit

let source = URL(fileURLWithPath: "Design/AppIcon")
let export = source.appendingPathComponent("export")
let defs = try String(contentsOf: source.appendingPathComponent("defs.svgfrag"), encoding: .utf8)

/// One picture as SVG: the shared definitions and the body's drawing, at its own size.
func svg(_ body: String) throws -> (Data, Int, Int) {
    let text = try String(contentsOf: source.appendingPathComponent(body + ".body"), encoding: .utf8)
    guard let header = text.split(separator: "\n").first, header.hasPrefix("<!-- size") else { fatalError("\(body): no size line") }
    let numbers = header.split(separator: " ").compactMap { Int($0) }
    let (w, h) = (numbers[0], numbers[1])
    let document = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
    \(defs)
    \(text)
    </svg>
    """
    return (Data(document.utf8), w, h)
}

/// Draws `body` at `width`×`height` pixels into a PNG; `opaque` drops the alpha channel
/// (the App Store icon may not have one).
func render(_ body: String, width: Int, height: Int, opaque: Bool, to url: URL) throws {
    let (data, _, _) = try svg(body)
    guard let image = NSImage(data: data) else { fatalError("\(body): macOS couldn't read the SVG") }
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    print("wrote \(url.path) (\(width)×\(height))")
}

try render("ios", width: 1024, height: 1024, opaque: true,
           to: URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
for (body, name, opaque) in [("ios-1-back", "back", true), ("ios-2-card", "card", false), ("ios-3-petals", "petals", false)] {
    try render(body, width: 1024, height: 1024, opaque: opaque, to: export.appendingPathComponent("ios/\(name).png"))
}
for (body, name, opaque) in [("tv-1-back", "back", true), ("tv-2-card", "card", false), ("tv-3-blossoms", "blossoms", false)] {
    for (w, h) in [(400, 240), (800, 480), (1280, 768)] {
        try render(body, width: w, height: h, opaque: opaque, to: export.appendingPathComponent("tvos/\(name)-\(w)x\(h).png"))
    }
}

// The Apple TV asset catalog (App/TV/Assets.xcassets): the layered app icon (front, middle,
// back image stacks at 400×240 @1x/@2x and 1280×768 for the App Store) and the top shelf.
let catalog = URL(fileURLWithPath: "App/TV/Assets.xcassets")
let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
func writeJSON(_ object: Any, to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("Contents.json"))
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try? FileManager.default.removeItem(at: catalog)
try writeJSON(["info": info], to: catalog)
try writeJSON(["info": info, "assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
]], to: brand)
let layers = [("Front", "tv-3-blossoms", false), ("Middle", "tv-2-card", false), ("Back", "tv-1-back", true)]
for (stack, scales) in [("App Icon - App Store", [(1280, 768, "1x")]), ("App Icon", [(400, 240, "1x"), (800, 480, "2x")])] {
    let folder = brand.appendingPathComponent("\(stack).imagestack")
    try writeJSON(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], to: folder)
    for (name, body, opaque) in layers {
        let layer = folder.appendingPathComponent("\(name).imagestacklayer")
        try writeJSON(["info": info], to: layer)
        let set = layer.appendingPathComponent("Content.imageset")
        var images: [[String: Any]] = []
        for (w, h, scale) in scales {
            let file = "\(name.lowercased())-\(w)x\(h).png"
            try render(body, width: w, height: h, opaque: opaque, to: set.appendingPathComponent(file))
            images.append(["filename": file, "idiom": "tv", "scale": scale])
        }
        try writeJSON(["info": info, "images": images], to: set)
    }
}
for (set, body, w, h) in [("Top Shelf Image Wide", "topshelf-wide", 2320, 720), ("Top Shelf Image", "topshelf", 1920, 720)] {
    let folder = brand.appendingPathComponent("\(set).imageset")
    var images: [[String: Any]] = []
    for (scale, factor) in [("1x", 1), ("2x", 2)] {
        let file = "topshelf-\(w * factor)x\(h * factor).png"
        try render(body, width: w * factor, height: h * factor, opaque: true, to: folder.appendingPathComponent(file))
        images.append(["filename": file, "idiom": "tv", "scale": scale])
    }
    try writeJSON(["info": info, "images": images], to: folder)
}
