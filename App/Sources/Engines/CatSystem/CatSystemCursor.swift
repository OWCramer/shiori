// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// A Windows cursor (`.cur`), as the game's `cursor/` folder has them (`cursor.xml`:
/// `cursor.cur`, and `cur_over.cur` over a button): the first image, with its hotspot.
/// Images are 32-bit BMPs (alpha in the colour data) or older ones with an AND mask, or PNG.
struct CatSystemCursor {
    let image: CGImage
    /// The point of the picture that sits on the pointer.
    let hotspot: CGPoint
    var size: CGSize { CGSize(width: image.width, height: image.height) }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: [UInt8](data))
    }

    init?(data b: [UInt8]) {
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }
        func s32(_ o: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(o))) }
        // ICONDIR: reserved, type (2 a cursor), count; then 16-byte entries.
        guard b.count > 22, u16(0) == 0, u16(2) == 2 || u16(2) == 1, u16(4) >= 1 else { return nil }
        let hotX = u16(10), hotY = u16(12)
        let size = u32(14), offset = u32(18)
        guard offset + min(size, 40) <= b.count else { return nil }
        let body = Array(b[offset..<min(b.count, offset + size)])
        if body.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            guard let provider = CGDataProvider(data: Data(body) as CFData),
                  let png = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            image = png
            hotspot = CGPoint(x: hotX, y: hotY)
            return
        }
        // BITMAPINFOHEADER: the height counts the colour rows and the AND mask's.
        let header = u32(offset)
        let width = s32(offset + 4), height = s32(offset + 8) / 2
        let bits = u16(offset + 14)
        guard header >= 40, width > 0, height > 0, width <= 256, height <= 256 else { return nil }
        let colors = bits <= 8 ? (u32(offset + 32) == 0 ? 1 << bits : u32(offset + 32)) : 0
        let palette = offset + header
        let pixels = palette + colors * 4
        let stride = ((width * bits + 31) / 32) * 4
        let maskStride = ((width + 31) / 32) * 4
        let mask = pixels + stride * height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var anyAlpha = false
        for y in 0..<height {
            let row = pixels + (height - 1 - y) * stride
            for x in 0..<width {
                var r = 0, g = 0, bl = 0, a = 255
                switch bits {
                case 32:
                    let p = row + x * 4
                    guard p + 3 < b.count else { continue }
                    bl = Int(b[p]); g = Int(b[p + 1]); r = Int(b[p + 2]); a = Int(b[p + 3])
                    if a != 0 { anyAlpha = true }
                case 24:
                    let p = row + x * 3
                    guard p + 2 < b.count else { continue }
                    bl = Int(b[p]); g = Int(b[p + 1]); r = Int(b[p + 2])
                case 8, 4, 1:
                    let bitIndex = x * bits
                    let p = row + bitIndex / 8
                    guard p < b.count else { continue }
                    let shift = 8 - bits - bitIndex % 8
                    let index = (Int(b[p]) >> shift) & ((1 << bits) - 1)
                    let c = palette + index * 4
                    guard c + 2 < b.count else { continue }
                    bl = Int(b[c]); g = Int(b[c + 1]); r = Int(b[c + 2])
                default:
                    return nil
                }
                let o = (y * width + x) * 4
                rgba[o] = UInt8(r); rgba[o + 1] = UInt8(g); rgba[o + 2] = UInt8(bl); rgba[o + 3] = UInt8(a)
            }
        }
        // Without alpha in the colours, the AND mask says which pixels are clear.
        if !anyAlpha {
            for y in 0..<height {
                let row = mask + (height - 1 - y) * maskStride
                for x in 0..<width {
                    let p = row + x / 8
                    let clear = p < b.count && (b[p] >> (7 - x % 8)) & 1 == 1
                    rgba[(y * width + x) * 4 + 3] = clear ? 0 : 255
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        image = cg
        hotspot = CGPoint(x: hotX, y: hotY)
    }
}
