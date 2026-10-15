import AVFoundation
import CatSystemKit
import Metal
import QuartzCore

/// A CatSystem2 movie (`movie nekopara3op`): WMV 9 video with WMA 2 sound in ASF, inside
/// `movie.int`. iOS plays neither, so a minimal FFmpeg (the ASF demuxer and the two decoders,
/// LGPL, `Scripts/catsystem/build-ios-ffmpeg.sh`) decodes them. The file is read from the
/// archive a piece at a time and deciphered in memory (nothing is written to disk). A thread
/// decodes a few frames ahead into Y, U and V textures and schedules the sound on its own
/// audio engine; the sound is the clock, and the frame for its time is drawn with Metal.
@MainActor
final class CatSystemMovie {
    let layer = CAMetalLayer()
    private let decoder: CatSystemMovieDecoder
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private let sampler: MTLSamplerState

    /// Opens `name` (`nekopara3op`, `.wmv` added) from the game's archives; nil when it isn't
    /// there or doesn't open.
    init?(name: String, game: CatSystemGame, volume: Float) {
        let file = name.lowercased().hasSuffix(".wmv") ? name : name + ".wmv"
        guard let stream = game.stream(named: file),
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaders, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "movieVertex")
        d.fragmentFunction = library.makeFunction(name: "movieFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d), let sampler = device.makeSamplerState(descriptor: s),
              let decoder = CatSystemMovieDecoder(size: stream.size, read: stream.read, device: device, volume: volume) else { return nil }
        self.pipeline = pipeline
        self.queue = queue
        self.sampler = sampler
        self.decoder = decoder
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        NSLog("CatSystem: movie %@ %dx%d, %.1f s", file, decoder.width, decoder.height, decoder.duration)
    }

    func start() { decoder.start() }

    /// True once the last frame has been shown and the sound has played out.
    var finished: Bool { decoder.finished }

    /// Ends playback (a tap skips): the decoding thread stops and frees FFmpeg's state.
    func stop() { decoder.stop() }

    /// Draws the frame for the sound's time (the last one again until the next is due).
    func draw() {
        guard let frame = decoder.frame(), let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Fit the picture in the drawable, centred (the movies are 1280×720, like the screen).
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let scale = min(dw / Double(frame.width), dh / Double(frame.height))
        var box = SIMD2<Float>(Float(Double(frame.width) * scale / dw), Float(Double(frame.height) * scale / dh))
        // The decoder's planes are wider than the picture when its rows are padded.
        var crop = SIMD2<Float>(Float(frame.width) / Float(frame.y.width), Float(frame.height) / Float(frame.y.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&box, length: 8, index: 0)
        encoder.setVertexBytes(&crop, length: 8, index: 1)
        encoder.setFragmentTexture(frame.y, index: 0)
        encoder.setFragmentTexture(frame.u, index: 1)
        encoder.setFragmentTexture(frame.v, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// BT.601, studio range (WMV 9's).
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut movieVertex(uint vid [[vertex_id]], constant float2 &box [[buffer(0)]], constant float2 &crop [[buffer(1)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        VOut out;
        out.position = float4((corner.x * 2 - 1) * box.x, (1 - corner.y * 2) * box.y, 0, 1);
        out.uv = corner * crop;
        return out;
    }
    fragment float4 movieFragment(VOut in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> u [[texture(1)]],
                                  texture2d<float> v [[texture(2)]], sampler s [[sampler(0)]]) {
        float Y = (y.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float U = (u.sample(s, in.uv).r - 128.0 / 255.0) * (255.0 / 224.0);
        float V = (v.sample(s, in.uv).r - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(Y + 1.402 * V, Y - 0.344136 * U - 0.714136 * V, Y + 1.772 * U);
        return float4(saturate(rgb), 1);
    }
    """
}

#if canImport(CFFmpeg)
import CFFmpeg

/// The FFmpeg side: demuxes and decodes on a thread of its own, a little ahead of the clock.
final class CatSystemMovieDecoder: @unchecked Sendable {
    struct Frame {
        var time: Double
        var width: Int
        var height: Int
        var y: MTLTexture
        var u: MTLTexture
        var v: MTLTexture
    }

    let width: Int
    let height: Int
    let duration: Double
    private let source: Source
    private let device: MTLDevice
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var io: UnsafeMutablePointer<AVIOContext>?
    private var video: UnsafeMutablePointer<AVCodecContext>?
    private var audio: UnsafeMutablePointer<AVCodecContext>?
    private let videoIndex: Int32
    private let audioIndex: Int32
    private let videoTimeBase: Double
    private let videoStart: Int64
    private let lock = NSLock()
    private var decoded: [Frame] = []
    private var current: Frame?
    private var running = false
    private var endOfFile = false
    private var thread: Thread?
    private var pool: [(y: MTLTexture, u: MTLTexture, v: MTLTexture)] = []
    private var poolIndex = 0
    private let ahead = 10

    // Sound: its own engine, so the movie's clock is the samples played. Kept sounding when
    // the output changes (GameAudioEngine); the player's own time starts again then, so the
    // clock carries on from where it was.
    private var output: GameAudioEngine?
    private let player = AVAudioPlayerNode()
    private var clockBase = 0.0
    private var lastPlayerSeconds = 0.0
    /// When the clock last moved (a sound that stopped for good ends the movie at its end).
    private var clockMoved = CACurrentMediaTime()
    private var lastClock = -1.0
    private var audioFormat: AVAudioFormat?
    private var scheduledSeconds = 0.0
    private var playedSeconds = 0.0
    private var buffersPlaying = 0
    private var wallStart: CFTimeInterval?
    private var shownCount = 0, skipped = 0
    private var lastReport = CACurrentMediaTime()
    private let volume: Float

    /// The archive file read in pieces (`read(offset, count)`), as FFmpeg asks for them.
    final class Source {
        let size: Int
        let read: (Int, Int) -> [UInt8]?
        var position = 0
        init(size: Int, read: @escaping (Int, Int) -> [UInt8]?) { self.size = size; self.read = read }
    }

    private static let eof: Int32 = -0x2046_4F45 // AVERROR_EOF: -MKTAG('E','O','F',' ')
    private static let again: Int32 = -35 // AVERROR(EAGAIN) on Darwin

    init?(size: Int, read: @escaping (Int, Int) -> [UInt8]?, device: MTLDevice, volume: Float) {
        source = Source(size: size, read: read)
        self.device = device
        self.volume = volume
        let bufferSize = 64 * 1024
        guard let buffer = av_malloc(bufferSize)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let opaque = Unmanaged.passUnretained(source).toOpaque()
        io = avio_alloc_context(buffer, Int32(bufferSize), 0, opaque, { opaque, out, count in
            let source = Unmanaged<CatSystemMovieDecoder.Source>.fromOpaque(opaque!).takeUnretainedValue()
            guard source.position < source.size else { return CatSystemMovieDecoder.eof }
            guard let bytes = source.read(source.position, Int(count)), !bytes.isEmpty else { return CatSystemMovieDecoder.eof }
            bytes.withUnsafeBufferPointer { out!.update(from: $0.baseAddress!, count: bytes.count) }
            source.position += bytes.count
            return Int32(bytes.count)
        }, nil, { opaque, offset, whence in
            let source = Unmanaged<CatSystemMovieDecoder.Source>.fromOpaque(opaque!).takeUnretainedValue()
            if whence & 0x10000 != 0 { return Int64(source.size) } // AVSEEK_SIZE
            let base: Int
            switch whence & 3 {
            case 0: base = 0 // SEEK_SET
            case 1: base = source.position
            case 2: base = source.size
            default: return -1
            }
            let target = base + Int(offset)
            guard target >= 0, target <= source.size else { return -1 }
            source.position = target
            return Int64(target)
        })
        guard let io else { av_free(buffer); return nil }
        format = avformat_alloc_context()
        format?.pointee.pb = io
        format?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        guard avformat_open_input(&format, nil, av_find_input_format("asf"), nil) == 0, let format,
              avformat_find_stream_info(format, nil) >= 0 else {
            Self.freeIO(&self.io)
            return nil
        }
        var v: Int32 = -1, a: Int32 = -1
        for i in 0..<Int(format.pointee.nb_streams) {
            guard let parameters = format.pointee.streams[i]?.pointee.codecpar else { continue }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO, v < 0 { v = Int32(i) }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO, a < 0 { a = Int32(i) }
        }
        func open(_ index: Int32) -> UnsafeMutablePointer<AVCodecContext>? {
            guard index >= 0, let stream = format.pointee.streams[Int(index)], let parameters = stream.pointee.codecpar,
                  let codec = avcodec_find_decoder(parameters.pointee.codec_id),
                  let context = avcodec_alloc_context3(codec) else { return nil }
            guard avcodec_parameters_to_context(context, parameters) >= 0, avcodec_open2(context, codec, nil) == 0 else {
                var owned: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&owned)
                return nil
            }
            return context
        }
        videoIndex = v
        audioIndex = a
        video = open(v)
        audio = open(a)
        guard let video, let stream = format.pointee.streams[Int(v)] else {
            Self.close(format: &self.format, io: &self.io, video: &self.video, audio: &self.audio)
            return nil
        }
        width = Int(video.pointee.width)
        height = Int(video.pointee.height)
        videoTimeBase = av_q2d(stream.pointee.time_base)
        videoStart = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
        duration = format.pointee.duration > 0 ? Double(format.pointee.duration) / 1_000_000 : 0
        if let audio, audio.pointee.ch_layout.nb_channels > 0 {
            audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(audio.pointee.sample_rate),
                                        channels: AVAudioChannelCount(audio.pointee.ch_layout.nb_channels))
        }
        // Planes for the frames held ahead (more while the sound catches up), the one shown and
        // the one being drawn.
        let padded = (width + 63) / 64 * 64
        for _ in 0..<(ahead * 2 + 3) {
            guard let y = plane(padded, height), let u = plane(padded / 2, (height + 1) / 2),
                  let v = plane(padded / 2, (height + 1) / 2) else { return nil }
            pool.append((y, u, v))
        }
    }

    deinit {
        // The thread frees FFmpeg's state when it ends; without one, free it here.
        if thread == nil { Self.close(format: &format, io: &io, video: &video, audio: &audio) }
    }

    private func plane(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    private static func freeIO(_ io: inout UnsafeMutablePointer<AVIOContext>?) {
        guard io != nil else { return }
        if let buffer = io?.pointee.buffer { av_free(buffer) }
        io?.pointee.buffer = nil
        avio_context_free(&io)
    }

    private static func close(format: inout UnsafeMutablePointer<AVFormatContext>?, io: inout UnsafeMutablePointer<AVIOContext>?,
                              video: inout UnsafeMutablePointer<AVCodecContext>?, audio: inout UnsafeMutablePointer<AVCodecContext>?) {
        avcodec_free_context(&video)
        avcodec_free_context(&audio)
        if format != nil { avformat_close_input(&format) }
        freeIO(&io)
    }

    func start() {
        if let audioFormat {
            let output = MainActor.assumeIsolated { GameAudioEngine(name: "CatSystem movie") }
            MainActor.assumeIsolated { output.attach(player, format: audioFormat, resume: .stream) }
            player.volume = volume
            self.output = output
        }
        lock.withLock { running = true }
        let thread = Thread { [self] in run() }
        thread.name = "catsystem.movie"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.withLock { running = false }
        player.stop()
        if let output { MainActor.assumeIsolated { output.close() } }
    }

    /// Seconds of the movie played: the sound's samples played, or the wall clock without
    /// sound (or before it starts).
    var clock: Double {
        if audioFormat != nil, let time = player.lastRenderTime, time.isSampleTimeValid,
           let played = player.playerTime(forNodeTime: time), played.sampleTime >= 0 {
            let seconds = Double(played.sampleTime) / played.sampleRate
            // Started again after an output change: on from where it was.
            if seconds + 0.25 < lastPlayerSeconds { clockBase += lastPlayerSeconds }
            lastPlayerSeconds = seconds
            let now = clockBase + seconds
            if now != lastClock { lastClock = now; clockMoved = CACurrentMediaTime() }
            return now
        }
        if audioFormat != nil, lastClock >= 0 { return lastClock }
        guard let wallStart else { return 0 }
        return CACurrentMediaTime() - wallStart
    }

    func frame() -> Frame? {
        if wallStart == nil, audioFormat == nil { wallStart = CACurrentMediaTime() }
        let now = clock
        lock.lock()
        var passed = 0
        while let first = decoded.first, first.time <= now {
            current = decoded.removeFirst()
            passed += 1
        }
        if passed > 1 { skipped += passed - 1 }
        if passed > 0 { shownCount += 1 }
        let report = CACurrentMediaTime() - lastReport >= 5
        if report {
            lastReport = CACurrentMediaTime()
            NSLog("CatSystem: movie at %.2f s, picture %.2f s, %d shown, %d skipped, %d ready", now, current?.time ?? -1, shownCount, skipped, decoded.count)
        }
        if current == nil, let first = decoded.first, audioFormat != nil, player.lastRenderTime == nil {
            // The first picture while the sound starts.
            current = first
        }
        let shown = current
        lock.unlock()
        return shown
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard endOfFile, decoded.isEmpty else { return !running && thread != nil }
        return audioFormat == nil || clock >= scheduledSeconds - 0.05 || buffersPlaying == 0
            || CACurrentMediaTime() - clockMoved > 1.5
    }

    // MARK: Decoding thread

    private func run() {
        guard let format, let packet = av_packet_alloc(), let picture = av_frame_alloc() else { return }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        var picturePointer: UnsafeMutablePointer<AVFrame>? = picture
        defer {
            av_packet_free(&packetPointer)
            av_frame_free(&picturePointer)
            Self.close(format: &self.format, io: &io, video: &video, audio: &audio)
            lock.withLock { running = false }
        }
        var started = false
        while lock.withLock({ running }) {
            let (held, audioAhead) = lock.withLock { (decoded.count, scheduledSeconds - clockUnlocked()) }
            // Enough ready: wait (the sound keeps a second or more queued).
            // The texture sets bound how far ahead pictures can go, whatever the sound needs.
            if held >= ahead && (audioFormat == nil || audioAhead > 1) || held >= pool.count - 3 {
                if !started { started = true; startPlayer() }
                Thread.sleep(forTimeInterval: 0.004)
                continue
            }
            let status = av_read_frame(format, packet)
            if status < 0 {
                if let video { decode(video, packet: nil, frame: picture) }
                if let audio { decode(audio, packet: nil, frame: picture) }
                if !started { startPlayer() }
                lock.withLock { endOfFile = true }
                // Stay until stopped, so the textures stay valid while the last frames show.
                while lock.withLock({ running }) { Thread.sleep(forTimeInterval: 0.02) }
                return
            }
            if packet.pointee.stream_index == videoIndex, let video {
                decode(video, packet: packet, frame: picture)
            } else if packet.pointee.stream_index == audioIndex, let audio {
                decode(audio, packet: packet, frame: picture)
            }
            av_packet_unref(packet)
        }
    }

    private func clockUnlocked() -> Double { audioFormat == nil ? 0 : playedSeconds }

    private func startPlayer() {
        guard audioFormat != nil else { return }
        player.play()
    }

    private func decode(_ context: UnsafeMutablePointer<AVCodecContext>, packet: UnsafeMutablePointer<AVPacket>?,
                        frame: UnsafeMutablePointer<AVFrame>) {
        guard avcodec_send_packet(context, packet) >= 0 || packet == nil else { return }
        while avcodec_receive_frame(context, frame) >= 0 {
            if context == video { picture(frame) } else { sound(frame) }
            av_frame_unref(frame)
        }
    }

    private func picture(_ f: UnsafeMutablePointer<AVFrame>) {
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        let set = pool[poolIndex]
        poolIndex = (poolIndex + 1) % pool.count
        guard w <= set.y.width, h <= set.y.height, let y = f.pointee.data.0, let u = f.pointee.data.1, let v = f.pointee.data.2 else { return }
        set.y.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: y, bytesPerRow: Int(f.pointee.linesize.0))
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        set.u.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: u, bytesPerRow: Int(f.pointee.linesize.1))
        set.v.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: v, bytesPerRow: Int(f.pointee.linesize.2))
        let pts = f.pointee.best_effort_timestamp == Int64.min ? f.pointee.pts : f.pointee.best_effort_timestamp
        let time = pts == Int64.min ? 0 : Double(pts - videoStart) * videoTimeBase
        lock.withLock { decoded.append(Frame(time: time, width: w, height: h, y: set.y, u: set.u, v: set.v)) }
    }

    private func sound(_ f: UnsafeMutablePointer<AVFrame>) {
        guard let audioFormat, f.pointee.nb_samples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(f.pointee.nb_samples)),
              let out = buffer.floatChannelData else { return }
        let count = Int(f.pointee.nb_samples)
        let channels = Int(audioFormat.channelCount)
        buffer.frameLength = AVAudioFrameCount(count)
        let sampleFormat = AVSampleFormat(rawValue: f.pointee.format)
        guard let planes = f.pointee.extended_data else { return }
        for c in 0..<channels {
            if sampleFormat == AV_SAMPLE_FMT_FLTP, let plane = planes[c] {
                plane.withMemoryRebound(to: Float.self, capacity: count) { out[c].update(from: $0, count: count) }
            } else if sampleFormat == AV_SAMPLE_FMT_FLT, let data = planes[0] {
                data.withMemoryRebound(to: Float.self, capacity: count * channels) { p in
                    for i in 0..<count { out[c][i] = p[i * channels + c] }
                }
            } else if sampleFormat == AV_SAMPLE_FMT_S16P, let plane = planes[c] {
                plane.withMemoryRebound(to: Int16.self, capacity: count) { p in
                    for i in 0..<count { out[c][i] = Float(p[i]) / 32768 }
                }
            } else {
                return
            }
        }
        let seconds = Double(count) / audioFormat.sampleRate
        lock.withLock {
            scheduledSeconds += seconds
            buffersPlaying += 1
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.playedSeconds += seconds
                self.buffersPlaying -= 1
            }
        }
    }
}
#else
/// Without FFmpeg (Apple TV for now) movies don't play; the story goes on past them.
final class CatSystemMovieDecoder: @unchecked Sendable {
    struct Frame {
        var time: Double
        var width: Int
        var height: Int
        var y: MTLTexture
        var u: MTLTexture
        var v: MTLTexture
    }

    let width = 0, height = 0, duration = 0.0
    init?(size: Int, read: @escaping (Int, Int) -> [UInt8]?, device: MTLDevice, volume: Float) { return nil }
    func start() {}
    func stop() {}
    func frame() -> Frame? { nil }
    var finished: Bool { true }
}
#endif
