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
/// (Settings › Engines; devices only) and with a bilinear sampler otherwise. Written for
/// ShioriKrkr; nothing here comes from the Standard engine's presenter or its shaders.
@MainActor
final class ShioriKrkrPresenter {
    let view: UIView
    private let layer: CAMetalLayer
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    /// Three textures in turn, so a new frame is never copied into one the GPU may still be
    /// reading.
    private var frameTextures: [MTLTexture] = []
    private var frameIndex = 0
    private let upscaling: Bool
    #if !targetEnvironment(simulator)
    private var scaler: MTLFXSpatialScaler?
    private var scaledTexture: MTLTexture?
    private var scalerSizes: (input: CGSize, output: CGSize) = (.zero, .zero)
    #endif

    private final class LayerView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

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

    init(upscaling: Bool) {
        let view = LayerView()
        self.view = view
        layer = view.layer as! CAMetalLayer
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        self.upscaling = upscaling
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        var pipeline: MTLRenderPipelineState?
        if let device, let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "shioriKrkrVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "shioriKrkrFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.pipeline = pipeline
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        sampler = device?.makeSamplerState(descriptor: samplerDescriptor)
        view.onLayout = { [weak self] in self?.resize() }
    }

    private func resize() {
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
    }

    /// Presents the frame (copying the pixels first when they've changed).
    func present(pixels: UnsafePointer<UInt8>, width: Int, height: Int, pitch: Int, changed: Bool) {
        guard let device, let queue, width > 0, height > 0 else { return }
        if frameTextures.first?.width != width || frameTextures.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            frameTextures = (0 ..< 3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        } else if !changed {
            return // Nothing new to show.
        }
        guard frameTextures.count == 3 else { return }
        frameIndex = (frameIndex + 1) % 3
        let frameTexture = frameTextures[frameIndex]
        frameTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                             bytesPerRow: pitch)
        guard let commands = queue.makeCommandBuffer() else { return }
        draw(frameTexture, width: width, height: height, commands: commands)
    }

    /// Presents a frame the engine composed on the GPU: `texture` is ready once `event`
    /// reaches `value`, which this frame's GPU work waits for.
    func present(texture: MTLTexture, event: MTLSharedEvent?, value: UInt64, width: Int, height: Int,
                 changed: Bool) {
        guard let queue, width > 0, height > 0 else { return }
        if !changed, lastEngineTexture === texture { return } // Nothing new to show.
        lastEngineTexture = texture
        guard let commands = queue.makeCommandBuffer() else { return }
        if let event { commands.encodeWaitForEvent(event, value: value) }
        draw(texture, width: width, height: height, commands: commands)
    }

    private weak var lastEngineTexture: MTLTexture?

    private func draw(_ frameTexture: MTLTexture, width: Int, height: Int, commands: MTLCommandBuffer) {
        guard let pipeline, layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else { return }

        // Where the game goes: aspect-fitted, in drawable pixels.
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let fitted = AVMakeRect(aspectRatio: CGSize(width: width, height: height),
                                insideRect: CGRect(origin: .zero, size: target)).integral
        var source: MTLTexture = frameTexture
        #if !targetEnvironment(simulator)
        if upscaling, let scaled = upscale(frameTexture, to: fitted.size, commands: commands) { source = scaled }
        #endif

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
    }

    #if !targetEnvironment(simulator)
    /// The frame enlarged to `size` by MetalFX; nil (bilinear instead) where it can't.
    private func upscale(_ input: MTLTexture, to size: CGSize, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let device, size.width > CGFloat(input.width) else { return nil }
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
