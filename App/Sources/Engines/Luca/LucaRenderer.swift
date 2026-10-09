import LucaKit
import Metal
import QuartzCore
import simd

/// Draws a Luca System stage with Metal: pictures in order with their blend modes, alpha and
/// scale; a DRAW's crossfade from a snapshot of the frame before; the shake; and the text
/// window (MWIN0's shape, tinted) with the speaker's face at its left end. Everything is in
/// the game's 1920×1080 space, letterboxed by the layer's frame.
///
/// The stage is rendered offscreen first, so a crossfade can blend the old frame over it and
/// save thumbnails can read it back.
@MainActor
final class LucaRenderer {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [Int: MTLRenderPipelineState] = [:]
    private var videoPipeline: MTLRenderPipelineState?
    /// Animated effects (MVT) on the stage, one per blend mode.
    private var videoLayerPipelines: [Int: MTLRenderPipelineState] = [:]
    private let sampler: MTLSamplerState
    let textures: LucaTextureCache

    /// The stage as last rendered, and the frame a DRAW is fading from.
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private var fade: (frames: Int, elapsed: Int)?

    static let stageSize = SIMD2<Float>(1920, 1080)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        textures = LucaTextureCache(device: device)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            for blend in 0...2 {
                pipelines[blend] = try Self.pipeline(device: device, library: library, blend: blend)
            }
            videoPipeline = try Self.pipeline(device: device, library: library, blend: 0, fragment: "luca_video_fragment")
            for blend in 0...2 {
                videoLayerPipelines[blend] = try Self.pipeline(device: device, library: library, blend: blend,
                                                               fragment: "luca_video_fragment")
            }
        } catch {
            NSLog("Luca: Metal shaders failed: %@", String(describing: error))
            return nil
        }
    }

    // MARK: Frame

    struct Window {
        var visible: Bool
        var mask: MTLTexture?
        var tint: SIMD4<Float>
        var rect: CGRect
        var face: (texture: MTLTexture, rect: CGRect)?
    }

    /// Starts a crossfade from what's on screen now, over `frames` (60 per second).
    func beginFade(frames: Int) {
        guard frames > 0, let current else { fade = nil; return }
        if previous == nil || previous!.width != current.width || previous!.height != current.height {
            previous = makeTarget(width: current.width, height: current.height)
        }
        guard let previous, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: current, to: previous)
        blit.endEncoding()
        buffer.commit()
        fade = (frames, 0)
    }

    func endFade() { fade = nil }

    /// One thing on the stage: a picture, or a frame of an animated effect.
    struct Item {
        enum Source {
            case picture(MTLTexture)
            /// Packing: 0 none, 1 alpha below the picture, 2 alpha right of it.
            case video(LucaVideoDecoder.Frame, packing: Int)
        }
        var layer: LucaLayer
        var source: Source
        var rect: CGRect
    }

    func draw(layers: [Item], shake: (x: Double, y: Double),
              window: Window, effects: LucaEffects) {
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let width = Int(size.width), height = Int(size.height)
        if current == nil || current!.width != width || current!.height != height {
            current = makeTarget(width: width, height: height)
            previous = nil
            fade = nil
        }
        guard let current else { return }

        // 1. The stage, offscreen.
        let stagePass = MTLRenderPassDescriptor()
        stagePass.colorAttachments[0].texture = current
        stagePass.colorAttachments[0].loadAction = .clear
        stagePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        stagePass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: stagePass) {
            encoder.setFragmentSamplerState(sampler, index: 0)
            for item in layers {
                var rect = item.rect
                rect.origin.x += shake.x
                rect.origin.y += shake.y
                switch item.source {
                case .picture(let texture):
                    quad(encoder, texture: texture, rect: rect, alpha: Float(item.layer.alpha),
                         blend: item.layer.blend, effects: effects)
                case .video(let frame, let packing):
                    videoQuad(encoder, frame: frame, rect: rect, alpha: Float(item.layer.alpha),
                              blend: item.layer.blend, packing: packing)
                }
            }
            encoder.endEncoding()
        }

        // 2. To the screen: the stage, the old frame fading out over it, then the window.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setFragmentSamplerState(sampler, index: 0)
            let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            quad(encoder, texture: current, rect: full, alpha: 1, blend: 0, effects: .none, mode: 3)
            if var f = fade, let previous {
                f.elapsed += 1
                let t = Float(f.elapsed) / Float(max(1, f.frames))
                quad(encoder, texture: previous, rect: full, alpha: max(0, 1 - t), blend: 0, effects: .none, mode: 3)
                fade = t >= 1 ? nil : f
            }
            if window.visible {
                if let mask = window.mask {
                    quad(encoder, texture: mask, rect: window.rect, alpha: 1, blend: 0, effects: .none,
                         mode: 1, tint: window.tint)
                }
                if let face = window.face {
                    // Clipped to the window, fading out towards the text.
                    let scale = Double(width) / 1920
                    encoder.setScissorRect(MTLScissorRect(x: 0, y: Int(window.rect.minY * scale),
                                                          width: Int(460 * scale), height: Int(window.rect.height * scale)))
                    quad(encoder, texture: face.texture, rect: face.rect, alpha: 1, blend: 0, effects: .none,
                         mode: 2, fade: SIMD2(330, 440))
                    encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
                }
            }
            encoder.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// The stage as last drawn, shrunk to `size`, for save thumbnails.
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard let current, let target = makeTarget(width: width, height: height, shared: true),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setFragmentSamplerState(sampler, index: 0)
        quad(encoder, texture: current, rect: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 1, blend: 0,
             effects: .none, mode: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A movie frame, letterboxed full screen, instead of the stage.
    func drawMovie(_ frame: LucaVideoDecoder.Frame?) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            if let frame, let pipeline = videoPipeline {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentSamplerState(sampler, index: 0)
                var u = Uniforms(rect: SIMD4(0, 0, 1920, 1080), stage: Self.stageSize, alpha: 1,
                                 mode: (frame.bt709 ? 1 : 0) | (frame.fullRange ? 2 : 0), tint: .zero, fade: .zero,
                                 sepia: 0, tone: .zero, addColor: .zero)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(frame.y, index: 0)
                encoder.setFragmentTexture(frame.u, index: 1)
                encoder.setFragmentTexture(frame.v, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    var metalDevice: MTLDevice { device }

    // MARK: Drawing

    private struct Uniforms {
        var rect: SIMD4<Float>      // x, y, w, h in stage pixels
        var stage: SIMD2<Float>
        var alpha: Float
        var mode: Int32             // 0 picture, 1 tinted mask, 2 face fade
        var tint: SIMD4<Float>
        var fade: SIMD2<Float>      // face: stage x where the fade starts and ends
        var sepia: Float
        var tone: SIMD4<Float>      // rgb multiply, a: 1 to apply
        var addColor: SIMD4<Float>
    }

    private func quad(_ encoder: MTLRenderCommandEncoder, texture: MTLTexture, rect: CGRect, alpha: Float, blend: Int,
                      effects: LucaEffects, mode: Int32 = 0, tint: SIMD4<Float> = .zero, fade: SIMD2<Float> = .zero) {
        guard alpha > 0.001, let pipeline = pipelines[blend] ?? pipelines[0] else { return }
        encoder.setRenderPipelineState(pipeline)
        var u = Uniforms(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                         stage: Self.stageSize, alpha: alpha, mode: mode, tint: tint, fade: fade,
                         sepia: effects.sepia, tone: effects.tone, addColor: effects.addColor)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func videoQuad(_ encoder: MTLRenderCommandEncoder, frame: LucaVideoDecoder.Frame, rect: CGRect, alpha: Float,
                           blend: Int, packing: Int) {
        guard alpha > 0.001, let pipeline = videoLayerPipelines[blend] ?? videoLayerPipelines[0] else { return }
        encoder.setRenderPipelineState(pipeline)
        var mode: Int32 = (frame.bt709 ? 1 : 0) | (frame.fullRange ? 2 : 0)
        if packing == 1 { mode |= 4 }
        if packing == 2 { mode |= 8 }
        var u = Uniforms(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                         stage: Self.stageSize, alpha: alpha, mode: mode, tint: .zero, fade: .zero,
                         sepia: 0, tone: .zero, addColor: .zero)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.y, index: 0)
        encoder.setFragmentTexture(frame.u, index: 1)
        encoder.setFragmentTexture(frame.v, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func makeTarget(width: Int, height: Int, shared: Bool = false) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: descriptor)
    }

    private static func pipeline(device: MTLDevice, library: MTLLibrary, blend: Int,
                                 fragment: String = "luca_fragment") throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "luca_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        switch blend {
        case 1: // additive
            color.destinationRGBBlendFactor = .one
            color.destinationAlphaBlendFactor = .one
        case 2: // screen
            color.destinationRGBBlendFactor = .oneMinusSourceColor
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        default: // over, premultiplied
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 rect; float2 stage; float alpha; int mode;
        float4 tint; float2 fade; float sepia; float4 tone; float4 addColor;
    };
    struct VOut { float4 position [[position]]; float2 uv; float2 stagePos; };

    vertex VOut luca_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = u.rect.xy + corner * u.rect.zw;
        VOut out;
        out.position = float4(p.x / u.stage.x * 2 - 1, 1 - p.y / u.stage.y * 2, 0, 1);
        out.uv = corner;
        out.stagePos = p;
        return out;
    }

    fragment float4 luca_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        if (u.mode == 1) {
            // A white shape: its alpha, in the tint colour.
            float a = c.a * u.tint.a;
            return float4(u.tint.rgb * a, a);
        }
        // Pictures are straight alpha (CZ); render targets (mode 3) are already premultiplied.
        if (u.mode != 3) {
            float3 rgb = c.rgb;
            if (u.sepia > 0) {
                float y = dot(rgb, float3(0.299, 0.587, 0.114));
                rgb = mix(rgb, float3(y * 1.07, y * 0.95, y * 0.80), u.sepia);
            }
            if (u.tone.a > 0) rgb *= u.tone.rgb;
            rgb = clamp(rgb + u.addColor.rgb, 0.0, 1.0);
            c = float4(rgb * c.a, c.a);
        }
        float a = u.alpha;
        if (u.mode == 2) a *= 1 - smoothstep(u.fade.x, u.fade.y, in.stagePos.x);
        return c * a;
    }

    // YUV 4:2:0 planes. mode bit 0: BT.709 (else BT.601); bit 1: full range (else studio).
    // bit 2: alpha packed below the picture (the top half is colour, the bottom half alpha);
    // bit 3: alpha packed right of it (the left half colour).
    fragment float4 luca_video_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                        texture2d<float> ty [[texture(0)]], texture2d<float> tu [[texture(1)]],
                                        texture2d<float> tv [[texture(2)]], sampler s [[sampler(0)]]) {
        bool below = (u.mode & 4) != 0, right = (u.mode & 8) != 0;
        float2 uv = in.uv;
        if (below) uv.y *= 0.5;
        if (right) uv.x *= 0.5;
        float y = ty.sample(s, uv).r, cb = tu.sample(s, uv).r - 0.5, cr = tv.sample(s, uv).r - 0.5;
        if ((u.mode & 2) == 0) { y = (y - 16.0 / 255.0) * (255.0 / 219.0); cb *= 255.0 / 224.0; cr *= 255.0 / 224.0; }
        float3 rgb = (u.mode & 1) != 0
            ? float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb)
            : float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb);
        rgb = clamp(rgb, 0.0, 1.0);
        float a = u.alpha;
        if (below || right) {
            float2 at = below ? float2(in.uv.x, 0.5 + in.uv.y * 0.5) : float2(0.5 + in.uv.x * 0.5, in.uv.y);
            float m = ty.sample(s, at).r;
            if ((u.mode & 2) == 0) m = (m - 16.0 / 255.0) * (255.0 / 219.0);
            a *= clamp(m, 0.0, 1.0);
        }
        return float4(rgb * a, a);
    }
    """
}

/// Colour effects the script turns on for the whole stage (SEPIA, TONE, ADDCOLOR).
struct LucaEffects {
    var sepia: Float = 0
    var tone = SIMD4<Float>(1, 1, 1, 0)
    var addColor = SIMD4<Float>.zero

    static let none = LucaEffects()
}

/// Pictures as Metal textures (mipmapped, so big backgrounds shrink cleanly), the most recent
/// up to about 400 MB. Textures can be made on any thread.
final class LucaTextureCache: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue?
    private let lock = NSLock()
    private var textures: [Int: MTLTexture] = [:]
    private var order: [Int] = []
    private var bytes = 0
    private let limit = 400 << 20

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()
    }

    func cached(_ id: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return textures[id]
    }

    /// The texture for picture `id`, made from `game` if needed (decoding happens here).
    func texture(_ id: Int, game: LucaGame, keep onScreen: Set<Int> = []) -> MTLTexture? {
        if let cached = cached(id) { return cached }
        guard let image = game.image(id), let texture = make(image) else { return nil }
        store(id, texture, keep: onScreen)
        return texture
    }

    func make(_ image: CZImage) -> MTLTexture? {
        let levels = Int(log2(Double(max(image.width, image.height)))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: levels > 1)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.rgba.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        if levels > 1, let buffer = queue?.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }

    func store(_ id: Int, _ texture: MTLTexture, keep onScreen: Set<Int> = []) {
        lock.lock()
        defer { lock.unlock() }
        if textures[id] == nil { bytes += texture.width * texture.height * 4 * 4 / 3 }
        textures[id] = texture
        order.removeAll { $0 == id }
        order.append(id)
        for old in order.dropLast() where bytes > limit && !onScreen.contains(old) {
            if let gone = textures.removeValue(forKey: old) { bytes -= gone.width * gone.height * 4 * 4 / 3 }
            order.removeAll { $0 == old }
        }
    }

    func removeAll() {
        lock.lock()
        textures.removeAll()
        order.removeAll()
        bytes = 0
        lock.unlock()
    }
}
