// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if canImport(CVPX)
import CVPX
import Foundation
import LucaKit
import Metal

/// Decodes a WebM's VP9 video with libvpx, a few frames ahead of playback on its own queue,
/// into Y, U and V planes in Metal textures for LucaRenderer.
final class LucaVideoDecoder: @unchecked Sendable {
    struct Frame {
        var time: Double
        var y: MTLTexture
        var u: MTLTexture
        var v: MTLTexture
        /// BT.709 (else BT.601), full range (else studio).
        var bt709: Bool
        var fullRange: Bool
    }

    let width: Int
    let height: Int
    let duration: Double
    private let frames: [WebM.Frame]
    private let device: MTLDevice
    private var context = vpx_codec_ctx_t()
    private var ready = false
    private let queue = DispatchQueue(label: "luca.video", qos: .userInteractive)
    private let lock = NSLock()
    private var decoded: [Frame] = []
    private var next = 0
    private var decoding = false
    /// Texture sets, reused round-robin: more than the frames held ahead, so a set isn't
    /// overwritten while the GPU still reads it.
    private var pool: [(y: MTLTexture, u: MTLTexture, v: MTLTexture)] = []
    private var poolIndex = 0
    private let ahead = 4
    /// Loops back to the start at the end (animated effects).
    let loops: Bool

    init?(webm: WebM, device: MTLDevice, loops: Bool = false) {
        guard let track = webm.video, track.codec == "V_VP9" else { return nil }
        frames = webm.frames.filter { $0.track == track.number }
        width = track.width
        height = track.height
        duration = max(webm.duration, frames.last?.time ?? 0)
        self.device = device
        self.loops = loops
        var config = vpx_codec_dec_cfg_t(threads: UInt32(min(4, ProcessInfo.processInfo.activeProcessorCount)), w: 0, h: 0)
        guard vpx_codec_dec_init_ver(&context, vpx_codec_vp9_dx(), &config, 0, 12) == VPX_CODEC_OK else { return nil }
        ready = true
        for _ in 0..<(ahead + 3) {
            guard let y = plane(width, height), let u = plane((width + 1) / 2, (height + 1) / 2),
                  let v = plane((width + 1) / 2, (height + 1) / 2) else { return nil }
            pool.append((y, u, v))
        }
    }

    deinit {
        if ready { vpx_codec_destroy(&context) }
    }

    private func plane(_ w: Int, _ h: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// The frame to show at `time` (seconds), dropping older ones, and keeps decoding ahead.
    func frame(at time: Double) -> Frame? {
        lock.lock()
        var shown: Frame?
        while let first = decoded.first, first.time <= time {
            shown = decoded.removeFirst()
        }
        let needMore = decoded.count < ahead && !decoding
        if needMore { decoding = true }
        lock.unlock()
        if needMore { queue.async { [weak self] in self?.decodeAhead() } }
        if let shown { current = shown }
        return current
    }

    private var current: Frame?

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !loops && next >= frames.count && decoded.isEmpty
    }

    private var loopOffset = 0.0

    private func decodeAhead() {
        defer {
            lock.lock()
            decoding = false
            lock.unlock()
        }
        while true {
            lock.lock()
            let full = decoded.count >= ahead
            lock.unlock()
            if full { return }
            if next >= frames.count {
                guard loops, !frames.isEmpty else { return }
                next = 0
                loopOffset += duration
            }
            let packet = frames[next]
            next += 1
            let status = packet.data.withUnsafeBytes { raw -> vpx_codec_err_t in
                vpx_codec_decode(&context, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count), nil, 0)
            }
            guard status == VPX_CODEC_OK else { continue }
            var iterator: vpx_codec_iter_t?
            while let image = vpx_codec_get_frame(&context, &iterator) {
                let set = pool[poolIndex]
                poolIndex = (poolIndex + 1) % pool.count
                let img = image.pointee
                let w = Int(img.d_w), h = Int(img.d_h)
                guard w <= set.y.width, h <= set.y.height else { continue }
                set.y.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                              withBytes: img.planes.0!, bytesPerRow: Int(img.stride.0))
                let cw = (w + 1) / 2, ch = (h + 1) / 2
                set.u.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0,
                              withBytes: img.planes.1!, bytesPerRow: Int(img.stride.1))
                set.v.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0,
                              withBytes: img.planes.2!, bytesPerRow: Int(img.stride.2))
                let frame = Frame(time: packet.time + loopOffset, y: set.y, u: set.u, v: set.v,
                                  bt709: img.cs == VPX_CS_BT_709, fullRange: img.range == VPX_CR_FULL_RANGE)
                lock.lock()
                decoded.append(frame)
                lock.unlock()
            }
        }
    }
}
#else
import Foundation
import LucaKit
import Metal

/// Apple TV: libvpx isn't built for tvOS yet, so VP9 movies and animated effects don't
/// start (the player shows the scene without them).
final class LucaVideoDecoder: @unchecked Sendable {
    struct Frame {
        var time: Double
        var y: MTLTexture
        var u: MTLTexture
        var v: MTLTexture
        var bt709: Bool
        var fullRange: Bool
    }

    let width = 0
    let height = 0
    let duration = 0.0
    let loops = false

    init?(webm: WebM, device: MTLDevice, loops: Bool = false) { return nil }

    func frame(at time: Double) -> Frame? { nil }

    var finished: Bool { true }
}
#endif
