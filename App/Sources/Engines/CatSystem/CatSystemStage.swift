import CatSystemKit
import Metal
import QuartzCore

/// The story's screen, drawn with Metal every frame: the planes under the characters (one
/// picture, made on the CPU when they change), the E-mote characters (CatSystemKit's
/// `EmoteGPU`, posed by `EmoteStage` for this moment), then the planes over them. A change
/// of scene crossfades from the last frame drawn. The drawable is the stage's size on
/// screen, so characters are drawn at the screen's resolution, not the game's 1280×720.
@MainActor
final class CatSystemStageRenderer {
    let layer = CAMetalLayer()
    private let gpu: EmoteGPU
    private let queue: MTLCommandQueue
    private var below: MTLTexture?
    private var above: MTLTexture?
    private var current: MTLTexture?
    private var previous: MTLTexture?
    private var fadeStart = 0.0
    private var fadeLength = 0.0
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

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let gpu = EmoteGPU(device: device, pixelFormat: .bgra8Unorm),
              let queue = device.makeCommandQueue() else { return nil }
        self.gpu = gpu
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        setUpFaceLayer()
    }

    /// The planes as pictures (1280×720 RGBA): `below` opaque, `above` premultiplied (nil
    /// when nothing is over the characters).
    func setPlanes(below: [UInt8], above: [UInt8]?) {
        self.below = texture(below)
        self.above = above.flatMap(texture)
    }

    /// A new texture each time (the GPU may still be reading the last one).
    private func texture(_ rgba: [UInt8]) -> MTLTexture? {
        guard rgba.count >= gameWidth * gameHeight * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: gameWidth, height: gameHeight, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let t = gpu.device.makeTexture(descriptor: d)
        rgba.withUnsafeBytes { t?.replace(region: MTLRegionMake2D(0, 0, gameWidth, gameHeight), mipmapLevel: 0,
                                         withBytes: $0.baseAddress!, bytesPerRow: gameWidth * 4) }
        return t
    }

    /// From the next frame, the screen crossfades from the last frame drawn over `seconds`.
    func crossfade(seconds: Double) {
        guard seconds > 0, current != nil else { return }
        swap(&previous, &current)
        fadeStart = CACurrentMediaTime()
        fadeLength = seconds
    }

    func endCrossfade() { fadeLength = 0 }

    var isFading: Bool { fadeLength > 0 && CACurrentMediaTime() < fadeStart + fadeLength }

    private func target(_ existing: MTLTexture?, width: Int, height: Int) -> MTLTexture? {
        if let existing, existing.width == width, existing.height == height { return existing }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return gpu.device.makeTexture(descriptor: d)
    }

    /// Draws a frame with `drawings` (from `EmoteStage`).
    func render(_ drawings: [EmoteStage.Drawing]) {
        let started = CACurrentMediaTime()
        let size = layer.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let below else { return }
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

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(current, clear: true)) else { return }
        let full = SIMD4<Float>(0, 0, Float(width), Float(height))
        gpu.drawQuad(below, encoder: encoder, width: width, height: height, rect: full)
        for c in characters {
            if let group = c.group {
                gpu.drawQuad(group, encoder: encoder, width: width, height: height, rect: full,
                             source: SIMD4(0, 0, Float(width) / Float(group.width), Float(height) / Float(group.height)), opacity: c.alpha)
            } else {
                gpu.draw(c.prepared, encoder: encoder, width: width, height: height)
            }
        }
        if let above { gpu.drawQuad(above, encoder: encoder, width: width, height: height, rect: full) }
        encoder.endEncoding()

        if let drawable = layer.nextDrawable(), let present = buffer.makeRenderCommandEncoder(descriptor: Self.pass(drawable.texture, clear: false)) {
            gpu.drawQuad(current, encoder: present, width: width, height: height, rect: full)
            let now = CACurrentMediaTime()
            if fadeLength > 0, let previous, previous.width == width, previous.height == height {
                let t = (now - fadeStart) / fadeLength
                if t < 1 {
                    gpu.drawQuad(previous, encoder: present, width: width, height: height, rect: full, opacity: Float(1 - t))
                } else {
                    fadeLength = 0
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
            NSLog("CatSystem: %d frames in %.1f s, CPU %.2f ms a frame, GPU %.2f ms, %d characters, %dx%d",
                  framesTimed, started - lastReport, cpuTotal / Double(max(1, framesTimed)) * 1000,
                  gpuSum / Double(max(1, gpuCount)) * 1000, drawings.count, width, height)
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

    private static func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clear ? 0 : 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}
