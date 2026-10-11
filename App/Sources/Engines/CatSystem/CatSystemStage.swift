import CatSystemKit
import Metal
import QuartzCore

/// What the story's Metal screen needs that takes a moment to make (shaders compiled from
/// source), made off the main thread when the game opens.
final class CatSystemStageResources: @unchecked Sendable {
    let gpu: EmoteGPU
    let wipePipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState

    private init(gpu: EmoteGPU, wipePipeline: MTLRenderPipelineState, sampler: MTLSamplerState) {
        self.gpu = gpu
        self.wipePipeline = wipePipeline
        self.sampler = sampler
    }

    static func make() -> CatSystemStageResources? {
        guard let device = MTLCreateSystemDefaultDevice(), let gpu = EmoteGPU(device: device, pixelFormat: .bgra8Unorm),
              let library = try? device.makeLibrary(source: shaders, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "wipeVertex")
        d.fragmentFunction = library.makeFunction(name: "wipeFragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d),
              let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        return CatSystemStageResources(gpu: gpu, wipePipeline: pipeline, sampler: sampler)
    }

    /// A rule wipe: the last frame drawn over the new one, gone where the rule picture's
    /// grey is below the wipe's progress (dark parts first), with a soft edge `vague` wide.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut wipeVertex(uint vid [[vertex_id]]) {
        float2 c = float2(vid & 1, vid >> 1);
        VOut out;
        out.position = float4(c.x * 2 - 1, 1 - c.y * 2, 0, 1);
        out.uv = c;
        return out;
    }
    fragment float4 wipeFragment(VOut in [[stage_in]], constant float2 &p [[buffer(0)]],
                                 texture2d<float> last [[texture(0)]], texture2d<float> rule [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
        float r = rule.sample(s, in.uv).r;
        float shown = saturate((p.x * (1 + p.y) - r) / p.y);
        return last.sample(s, in.uv) * (1 - shown);
    }
    """
}

/// The story's screen, drawn with Metal every frame: the planes under the characters (each
/// picture or colour a textured rectangle, placed, scaled, faded and shaken for this moment
/// by `PlaneStage`), the E-mote characters (CatSystemKit's `EmoteGPU`, posed by
/// `EmoteStage`), then the planes over them. A change of scene crossfades from the last
/// frame drawn, or wipes through a rule picture (`rwipe wipe04a`). The drawable is the
/// stage's size on screen, so characters are drawn at the screen's resolution, not the
/// game's 1280×720.
@MainActor
final class CatSystemStageRenderer {
    let layer = CAMetalLayer()
    private let gpu: EmoteGPU
    private let resources: CatSystemStageResources
    private let queue: MTLCommandQueue
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private var fadeStart = 0.0
    private var fadeLength = 0.0
    /// The rule picture of the transition under way (nil: a crossfade).
    private var rule: MTLTexture?
    private let gameWidth = 1280, gameHeight = 720
    /// When each model's textures became ready, if a frame had to wait for them (-1 while
    /// waiting).
    private var readySince: [ObjectIdentifier: Double] = [:]

    // Frame times, logged every few seconds.
    private var cpuTotal = 0.0, gpuTotal = 0.0, framesTimed = 0, gpuFrames = 0
    private var lastReport = CACurrentMediaTime()
    private let gpuLock = NSLock()
    nonisolated(unsafe) private var gpuSum = 0.0
    nonisolated(unsafe) private var gpuCount = 0

    init?(resources: CatSystemStageResources) {
        guard let queue = resources.gpu.device.makeCommandQueue() else { return nil }
        self.resources = resources
        gpu = resources.gpu
        self.queue = queue
        layer.device = gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        setUpFaceLayer()
    }

    // MARK: Planes

    /// A plane's picture or colour as drawn this frame: a rectangle in game pixels (it may
    /// reach past the screen), faded to `alpha` (0–1).
    struct PlaneDrawing {
        var texture: MTLTexture
        var x: Double, y: Double, width: Double, height: Double
        var alpha: Double
    }

    /// A picture as a texture: RGBA, premultiplied (`HGImage.Frame.premultipliedRGBA`) unless
    /// it is opaque.
    func texture(rgba: [UInt8], width: Int, height: Int, premultiplied: Bool = true) -> MTLTexture? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = gpu.device.makeTexture(descriptor: d)
        rgba.withUnsafeBytes { t?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                           withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return t
    }

    /// A 1×1 texture of a colour (`0xAARRGGBB`), premultiplied, for colour planes.
    func texture(color: UInt32) -> MTLTexture? {
        let a = UInt32(color >> 24)
        func c(_ shift: UInt32) -> UInt8 { UInt8(((color >> shift & 0xFF) * a + 127) / 255) }
        return texture(rgba: [c(16), c(8), c(0), UInt8(a)], width: 1, height: 1)
    }

    /// A rule picture's grey levels as a texture.
    func ruleTexture(grey: [UInt8], width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0, grey.count >= width * height else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = gpu.device.makeTexture(descriptor: d)
        grey.withUnsafeBytes { t?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                           withBytes: $0.baseAddress!, bytesPerRow: width) }
        return t
    }

    // MARK: Transitions

    /// From the next frame, the screen crossfades from the last frame drawn over `seconds`,
    /// or wipes by `rule` (a rule picture's texture) when one is given.
    func transition(seconds: Double, rule: MTLTexture? = nil) {
        guard seconds > 0, current != nil else { return }
        swap(&previous, &current)
        fadeStart = CACurrentMediaTime()
        fadeLength = seconds
        self.rule = rule
    }

    func crossfade(seconds: Double) { transition(seconds: seconds) }

    func endCrossfade() { fadeLength = 0 }

    var isFading: Bool { fadeLength > 0 && CACurrentMediaTime() < fadeStart + fadeLength }

    private func target(_ existing: MTLTexture?, width: Int, height: Int) -> MTLTexture? {
        if let existing, existing.width == width, existing.height == height { return existing }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return gpu.device.makeTexture(descriptor: d)
    }

    // MARK: Frames

    /// Draws a frame: `below` (the planes under the characters, in order), `drawings` (from
    /// `EmoteStage`), then `above`.
    func render(below: [PlaneDrawing], _ drawings: [EmoteStage.Drawing], above: [PlaneDrawing]) {
        let started = CACurrentMediaTime()
        let size = layer.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }
        current = target(current, width: width, height: height)
        guard let current, let buffer = queue.makeCommandBuffer() else { return }
        let s = Double(width) / Double(gameWidth)

        // Characters: evaluated, masks and (for a fading character) a picture of their own,
        // all before the pass that puts the screen together.
        var characters: [(prepared: EmoteGPU.Prepared, alpha: Float, group: MTLTexture?)] = []
        for var d in drawings {
            let model = d.renderer.model
            let key = ObjectIdentifier(model)
            guard gpu.texturesReady(for: model) else { readySince[key] = -1; continue }
            // A character whose textures were still uploading fades in once they are there.
            let since = readySince[key] ?? 0
            if since < 0 { readySince[key] = started }
            let ramp = since < 0 ? 0 : min(1, (started - since) / 0.25)
            if ramp < 1, d.alpha > 0 { d = d.fading(d.alpha * ramp) }
            let list = d.renderer.drawList(variables: d.variables,
                                           transform: (d.scaleX * s, 0, 0, d.scaleY * s, d.x * s, d.y * s))
            guard let prepared = gpu.prepare(list, model: model, buffer: buffer) else { continue }
            var group: MTLTexture?
            if d.alpha < 0.999, let t = gpu.scratch(width: width, height: height, format: .bgra8Unorm, for: buffer),
               let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(t, clear: true)) {
                gpu.draw(prepared, encoder: encoder, width: width, height: height)
                encoder.endEncoding()
                group = t
            }
            characters.append((prepared, Float(d.alpha), group))
        }

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(current, clear: true, black: true)) else { return }
        let full = SIMD4<Float>(0, 0, Float(width), Float(height))
        func plane(_ p: PlaneDrawing) {
            guard p.alpha > 0.002 else { return }
            gpu.drawQuad(p.texture, encoder: encoder, width: width, height: height,
                         rect: SIMD4(Float(p.x * s), Float(p.y * s), Float(p.width * s), Float(p.height * s)),
                         opacity: Float(min(1, p.alpha)))
        }
        below.forEach(plane)
        for c in characters {
            if let group = c.group {
                gpu.drawQuad(group, encoder: encoder, width: width, height: height, rect: full,
                             source: SIMD4(0, 0, Float(width) / Float(group.width), Float(height) / Float(group.height)), opacity: c.alpha)
            } else {
                gpu.draw(c.prepared, encoder: encoder, width: width, height: height)
            }
        }
        above.forEach(plane)
        encoder.endEncoding()

        if let drawable = layer.nextDrawable(), let present = buffer.makeRenderCommandEncoder(descriptor: Self.pass(drawable.texture, clear: false)) {
            gpu.drawQuad(current, encoder: present, width: width, height: height, rect: full)
            let now = CACurrentMediaTime()
            if fadeLength > 0, let previous, previous.width == width, previous.height == height {
                let t = (now - fadeStart) / fadeLength
                if t >= 1 {
                    fadeLength = 0
                } else if let rule {
                    var p = SIMD2<Float>(Float(t), 0.12)
                    present.setRenderPipelineState(resources.wipePipeline)
                    present.setFragmentBytes(&p, length: 8, index: 0)
                    present.setFragmentTexture(previous, index: 0)
                    present.setFragmentTexture(rule, index: 1)
                    present.setFragmentSamplerState(resources.sampler, index: 0)
                    present.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                } else {
                    gpu.drawQuad(previous, encoder: present, width: width, height: height, rect: full, opacity: Float(1 - t))
                }
            }
            present.endEncoding()
            buffer.present(drawable)
        }
        buffer.addCompletedHandler { [weak self] b in
            let gpuTime = b.gpuEndTime - b.gpuStartTime
            guard let self, gpuTime > 0 else { return }
            self.gpuLock.withLock {
                self.gpuSum += gpuTime
                self.gpuCount += 1
            }
        }
        buffer.commit()

        cpuTotal += CACurrentMediaTime() - started
        framesTimed += 1
        if started - lastReport >= 5 {
            let (gpuSum, gpuCount) = gpuLock.withLock { () -> (Double, Int) in
                defer { self.gpuSum = 0; self.gpuCount = 0 }
                return (self.gpuSum, self.gpuCount)
            }
            NSLog("CatSystem: %d frames in %.1f s, CPU %.2f ms a frame, GPU %.2f ms, %d characters, %d planes, %dx%d",
                  framesTimed, started - lastReport, cpuTotal / Double(max(1, framesTimed)) * 1000,
                  gpuSum / Double(max(1, gpuCount)) * 1000, drawings.count, below.count + above.count, width, height)
            cpuTotal = 0
            framesTimed = 0
            lastReport = started
        }
    }

    // MARK: Faces

    /// The message window's face box (`fmpl`): the window's left 262×260 (the game's
    /// `sys_meswnd` frame 30) and 60 above it for the ears, over the window's art. Its own transparent layer, since the
    /// window is drawn by UIKit over the screen.
    let faceLayer = CAMetalLayer()
    static let faceBox = CGRect(x: 0, y: -60, width: 262, height: 320)
    private var facesShown = false

    private func setUpFaceLayer() {
        faceLayer.device = gpu.device
        faceLayer.pixelFormat = .bgra8Unorm
        faceLayer.framebufferOnly = true
        faceLayer.isOpaque = false
        faceLayer.maximumDrawableCount = 3
        faceLayer.isHidden = true
    }

    /// Draws the faces: a face model's origin, where the scene's default place (640, 360)
    /// would put it, goes to (130, 290) in the window, which shows the head and shoulders.
    func renderFaces(_ drawings: [EmoteStage.Drawing]) {
        let ready = drawings.filter { gpu.texturesReady(for: $0.renderer.model) }
        faceLayer.isHidden = ready.isEmpty
        guard !ready.isEmpty || facesShown else { return }
        facesShown = !ready.isEmpty
        let size = faceLayer.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let buffer = queue.makeCommandBuffer() else { return }
        let s = Double(width) / Self.faceBox.width
        var prepared: [(EmoteGPU.Prepared, Float)] = []
        for d in ready {
            let x = d.x - 640 + 130 - Self.faceBox.minX, y = d.y - 520 + 290 - Self.faceBox.minY
            let list = d.renderer.drawList(variables: d.variables, transform: (d.scaleX * s, 0, 0, d.scaleY * s, x * s, y * s))
            if let p = gpu.prepare(list, model: d.renderer.model, buffer: buffer) { prepared.append((p, Float(d.alpha))) }
        }
        guard let drawable = faceLayer.nextDrawable(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(drawable.texture, clear: true)) else { return }
        for (p, alpha) in prepared { gpu.draw(p, encoder: encoder, width: width, height: height, opacity: alpha) }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static func pass(_ texture: MTLTexture, clear: Bool, black: Bool = false) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clear && !black ? 0 : 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}
