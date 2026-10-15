// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import AVFoundation
import Metal
import QuartzCore
import UIKit
#if !targetEnvironment(simulator)
import MetalFX
#endif

/// Shows ShioriKrkr's composed frames: the engine's own texture when it composes on the GPU
/// (waiting on its event), otherwise each new frame copied into a texture; then drawn
/// aspect-fitted into a CAMetalLayer, enlarged with MetalFX's spatial scaler where it's on
/// (Settings › Engines; devices only) and with a bilinear sampler otherwise.
///
/// Presentation runs on a queue of its own: the engine's tick only hands over the newest frame
/// and returns, and the queue waits for a drawable (a frame not yet shown is replaced by a newer
/// one). Waiting for drawables on the engine's thread tied its ticks to the display and held
/// busy scenes at around 30. Every display refresh presents something: with no new frame the
/// last picture (already enlarged) goes up again, so ProMotion stays at the display link's 60
/// instead of slowing while the game is still and ramping up when it moves again.
@MainActor
final class ShioriKrkrPresenter {
    let view: UIView
    private let layer: CAMetalLayer
    private let device: MTLDevice?
    private let renderer: Renderer?
    /// Three textures in turn, so a new frame is never copied into one the GPU may still be
    /// reading (the CPU-composed path).
    private var frameTextures: [MTLTexture] = []
    private var frameIndex = 0
    private weak var lastEngineTexture: MTLTexture?

    private final class LayerView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    init(upscaling: Bool) {
        let view = LayerView()
        self.view = view
        let metalLayer = view.layer as! CAMetalLayer
        let metalDevice = MTLCreateSystemDefaultDevice()
        metalLayer.device = metalDevice
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        device = metalDevice
        renderer = metalDevice.flatMap { Renderer(device: $0, layer: metalLayer, upscaling: upscaling) }
        view.onLayout = { [weak self] in self?.resize() }
    }

    private func resize() {
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        layer.contentsScale = scale
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard size != layer.drawableSize else { return }
        layer.drawableSize = size
        renderer?.redraw() // the last frame again, at the new size
    }

    /// Presents the frame (copying the pixels first when they've changed).
    func present(pixels: UnsafePointer<UInt8>, width: Int, height: Int, pitch: Int, changed: Bool) {
        guard let device, let renderer, width > 0, height > 0 else { return }
        if frameTextures.first?.width != width || frameTextures.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            frameTextures = (0 ..< 3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        } else if !changed {
            renderer.repeatLast() // the same picture again: the display keeps its 60
            return
        }
        guard frameTextures.count == 3 else { return }
        frameIndex = (frameIndex + 1) % 3
        let frameTexture = frameTextures[frameIndex]
        frameTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                             bytesPerRow: pitch)
        renderer.submit(.init(texture: frameTexture, event: nil, value: 0, width: width, height: height))
    }

    /// Presents a frame the engine composed on the GPU: `texture` is ready once `event`
    /// reaches `value`, which the presentation's GPU work waits for. Called every display
    /// refresh; only a new frame is handed on (the layer keeps showing the last one).
    func present(texture: MTLTexture, event: MTLSharedEvent?, value: UInt64, width: Int, height: Int,
                 changed: Bool) {
        guard let renderer, width > 0, height > 0 else { return }
        let fresh = changed || lastEngineTexture !== texture
        lastEngineTexture = texture
        guard fresh else {
            renderer.repeatLast() // the same picture again: the display keeps its 60
            return
        }
        renderer.submit(.init(texture: texture, event: event, value: value, width: width, height: height))
    }

    /// Frames shown since the last call, how many were new, the time the presentation
    /// queue spent waiting for drawables, and frames replaced by a newer one before they could
    /// be shown.
    func takeStatistics() -> (shown: Int, new: Int, drawableWait: CFTimeInterval, skipped: Int) {
        renderer?.takeStatistics() ?? (0, 0, 0, 0)
    }
}

/// The presentation queue's side: everything here runs on `queue`, except `submit`, `redraw`
/// and `takeStatistics`, which hand over under `lock`.
private final class Renderer: @unchecked Sendable {
    struct Frame {
        let texture: MTLTexture
        let event: MTLSharedEvent?
        let value: UInt64
        let width: Int, height: Int
    }

    private let device: MTLDevice
    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let upscaling: Bool
    private let queue = DispatchQueue(label: "com.owencramer.shiori.krkr-presenter", qos: .userInteractive)

    private let lock = NSLock()
    private var pending: Frame?
    private var draining = false
    private var redrawWanted = false
    private var shown = 0, fresh = 0, dropped = 0
    private var drawableWait: CFTimeInterval = 0

    // Queue-only state.
    private var lastFrame: Frame?
    private var lastSource: MTLTexture?
    #if !targetEnvironment(simulator)
    private var scaler: MTLFXSpatialScaler?
    private var scaledTexture: MTLTexture?
    private var scalerSizes: (input: CGSize, output: CGSize) = (.zero, .zero)
    #endif

    /// Draws a texture over a rectangle given in clip space (x0, y0, x1, y1); its alpha is
    /// ignored (KiriKiri's primary layer is opaque, but not every pixel says so).
    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        vertex Out shioriKrkrVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
            float2 corner = float2(id & 1, id >> 1);
            Out out;
            out.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.y, rect.w, corner.y), 0, 1);
            out.uv = float2(corner.x, 1 - corner.y);
            return out;
        }
        fragment float4 shioriKrkrFragment(Out in [[stage_in]], texture2d<float> frame [[texture(0)]],
                                           sampler linear [[sampler(0)]]) {
            return float4(frame.sample(linear, in.uv).rgb, 1);
        }
        """

    init?(device: MTLDevice, layer: CAMetalLayer, upscaling: Bool) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "shioriKrkrVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "shioriKrkrFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.layer = layer
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.sampler = sampler
        self.upscaling = upscaling
    }

    /// The newest frame, replacing one not yet shown; returns at once.
    func submit(_ frame: Frame) {
        lock.lock()
        if pending != nil { dropped += 1 }
        pending = frame
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// The last picture presented again, unless something is already on its way (called on
    /// refreshes with no new frame).
    func repeatLast() {
        lock.lock()
        guard !draining, pending == nil else {
            lock.unlock()
            return
        }
        redrawWanted = true
        draining = true
        lock.unlock()
        queue.async { self.drain() }
    }

    /// The last frame drawn again (the drawable changed size).
    func redraw() {
        lock.lock()
        redrawWanted = true
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func takeStatistics() -> (shown: Int, new: Int, drawableWait: CFTimeInterval, skipped: Int) {
        lock.lock()
        defer { shown = 0; fresh = 0; dropped = 0; drawableWait = 0; lock.unlock() }
        return (shown, fresh, drawableWait, dropped)
    }

    private func drain() {
        while true {
            lock.lock()
            let frame = pending
            let again = redrawWanted
            pending = nil
            redrawWanted = false
            if frame == nil && !again {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let frame {
                lastFrame = frame
                draw(frame, fresh: true)
            } else if let lastFrame {
                draw(lastFrame, fresh: false)
            }
        }
    }

    private func draw(_ frame: Frame, fresh: Bool) {
        guard layer.drawableSize.width > 0, let commands = commandQueue.makeCommandBuffer() else { return }
        if fresh, let event = frame.event { commands.encodeWaitForEvent(event, value: frame.value) }
        let waitStart = CACurrentMediaTime()
        guard let drawable = layer.nextDrawable() else { return }
        let waited = CACurrentMediaTime() - waitStart

        // Where the game goes: aspect-fitted, in drawable pixels.
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let fitted = AVMakeRect(aspectRatio: CGSize(width: frame.width, height: frame.height),
                                insideRect: CGRect(origin: .zero, size: target)).integral
        var source: MTLTexture = frame.texture
        if !fresh, let last = lastSource {
            source = last
        } else {
            #if !targetEnvironment(simulator)
            if upscaling, let scaled = upscale(frame.texture, to: fitted.size, commands: commands) { source = scaled }
            #endif
            lastSource = source
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var rect = SIMD4<Float>(Float(fitted.minX / target.width * 2 - 1), Float(1 - fitted.maxY / target.height * 2),
                                Float(fitted.maxX / target.width * 2 - 1), Float(1 - fitted.minY / target.height * 2))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        lock.lock()
        shown += 1
        if fresh { self.fresh += 1 }
        drawableWait += waited
        lock.unlock()
    }

    #if !targetEnvironment(simulator)
    /// The frame enlarged to `size` by MetalFX; nil (bilinear instead) where it can't.
    private func upscale(_ input: MTLTexture, to size: CGSize, commands: MTLCommandBuffer) -> MTLTexture? {
        guard size.width > CGFloat(input.width) else { return nil }
        let inputSize = CGSize(width: input.width, height: input.height)
        if scaler == nil || scalerSizes.input != inputSize || scalerSizes.output != size {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = input.width
            descriptor.inputHeight = input.height
            descriptor.outputWidth = Int(size.width)
            descriptor.outputHeight = Int(size.height)
            descriptor.colorTextureFormat = input.pixelFormat
            descriptor.outputTextureFormat = .rgba8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard MTLFXSpatialScalerDescriptor.supportsDevice(device),
                  let made = descriptor.makeSpatialScaler(device: device)
            else { return nil }
            let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Int(size.width),
                                                                  height: Int(size.height), mipmapped: false)
            output.usage = made.outputTextureUsage
            output.storageMode = .private
            scaledTexture = device.makeTexture(descriptor: output)
            scaler = made
            scalerSizes = (inputSize, size)
        }
        guard let scaler, let scaledTexture else { return nil }
        scaler.colorTexture = input
        scaler.outputTexture = scaledTexture
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.encode(commandBuffer: commands)
        return scaledTexture
    }
    #endif
}
