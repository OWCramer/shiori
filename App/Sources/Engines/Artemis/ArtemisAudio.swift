import ArtemisKit
import AVFoundation

/// Artemis sound: one music channel (`splay`/`sstop`/`sfade`) and numbered effect/voice
/// channels (`seplay`/`sestop`/`sefade`), with loops, fades and 0...1000 gains. Ogg Vorbis
/// is decoded with ArtemisKit; other formats through AVAudioFile.
@MainActor
final class ArtemisAudio {
    private let engine = AVAudioEngine()
    private var music: AVAudioPlayerNode?
    private var effects: [String: AVAudioPlayerNode] = [:]
    private struct Fade {
        let node: AVAudioPlayerNode
        let from: Float
        let to: Float
        let began: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (() -> Void)?
    }

    /// Running volume fades, advanced by `tick()` every frame.
    private var fades: [ObjectIdentifier: Fade] = [:]

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func handle(_ tag: ArtemisTag, data: (String) -> Data?) {
        switch tag.name {
        case "splay":
            stop(music, fadeMs: 0)
            music = play(tag["file"], loop: tag["loop"] != "0", fadeIn: tag.number("time"), gain: tag.number("gain", default: 1000), data: data)
        case "sstop":
            stop(music, fadeMs: tag.number("time"))
            music = nil
        case "sfade":
            fade(music, to: tag.number("gain", default: 1000) / 1000, ms: tag.number("time"))
        case "seplay", "voice":
            let id = tag["id"] ?? "0"
            stop(effects[id], fadeMs: 0)
            effects[id] = play(tag["file"], loop: tag["loop"] == "1", fadeIn: 0, gain: tag.number("gain", default: 1000), data: data)
        case "sestop", "vstop":
            let id = tag["id"] ?? "0"
            stop(effects[id], fadeMs: tag.number("time"))
            effects[id] = nil
        case "sefade":
            fade(effects[tag["id"] ?? "0"], to: tag.number("gain", default: 1000) / 1000, ms: tag.number("time"))
        default:
            break
        }
    }

    func stopAll() {
        stop(music, fadeMs: 0)
        music = nil
        for node in effects.values { stop(node, fadeMs: 0) }
        effects.removeAll()
        engine.stop()
    }

    // MARK: -

    private func buffer(_ file: String, data: (String) -> Data?) -> AVAudioPCMBuffer? {
        for candidate in [file, file + ".ogg", file + ".wav", file + ".m4a", file + ".mp3"] {
            guard let bytes = data(candidate) else { continue }
            if let pcm = decodeOggVorbis(bytes) { return Self.buffer(from: pcm) }
            // Not Ogg: let AVFoundation read it from a temporary file.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("artemis-sound." + ((candidate as NSString).pathExtension.isEmpty ? "wav" : (candidate as NSString).pathExtension))
            guard (try? bytes.write(to: url)) != nil, let audioFile = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length))
            else { continue }
            try? audioFile.read(into: buffer)
            return buffer
        }
        return nil
    }

    private static func buffer(from pcm: ArtemisPCM) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(pcm.sampleRate), channels: AVAudioChannelCount(pcm.channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        let channels = pcm.channels
        pcm.samples.withUnsafeBufferPointer { samples in
            for channel in 0 ..< channels {
                let out = buffer.floatChannelData![channel]
                for frame in 0 ..< pcm.frameCount {
                    out[frame] = Float(samples[frame * channels + channel]) / 32768
                }
            }
        }
        return buffer
    }

    private func play(_ file: String?, loop: Bool, fadeIn: Double, gain: Double, data: (String) -> Data?) -> AVAudioPlayerNode? {
        guard let file, !file.isEmpty, let buffer = buffer(file, data: data) else { return nil }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        if !engine.isRunning { try? engine.start() }
        let volume = Float(gain / 1000)
        node.volume = fadeIn > 0 ? 0 : volume
        // A-B repeat: "<name>_a" plays once, then "<name>_b" loops (when it exists).
        if loop, file.hasSuffix("_a"), let loopPart = self.buffer(String(file.dropLast(2)) + "_b", data: data),
           loopPart.format == buffer.format {
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            node.scheduleBuffer(loopPart, at: nil, options: [.loops], completionHandler: nil)
        } else {
            node.scheduleBuffer(buffer, at: nil, options: loop ? [.loops] : [], completionHandler: nil)
        }
        node.play()
        if fadeIn > 0 { fade(node, to: Double(volume), ms: fadeIn) }
        return node
    }

    private func stop(_ node: AVAudioPlayerNode?, fadeMs: Double) {
        guard let node else { return }
        if fadeMs > 0 {
            fade(node, to: 0, ms: fadeMs) { [weak self] in self?.remove(node) }
        } else {
            remove(node)
        }
    }

    private func remove(_ node: AVAudioPlayerNode) {
        fades[ObjectIdentifier(node)] = nil
        node.stop()
        if node.engine != nil { engine.detach(node) }
    }

    private func fade(_ node: AVAudioPlayerNode?, to target: Double, ms: Double, completion: (() -> Void)? = nil) {
        guard let node else { return }
        guard ms > 0 else {
            fades[ObjectIdentifier(node)] = nil
            node.volume = Float(target)
            completion?()
            return
        }
        fades[ObjectIdentifier(node)] = Fade(node: node, from: node.volume, to: Float(target), began: CACurrentMediaTime(),
                                             duration: ms / 1000, completion: completion)
    }

    /// Advances fades; call every frame.
    func tick() {
        let now = CACurrentMediaTime()
        for (key, fade) in fades {
            let t = Float(min(1, (now - fade.began) / fade.duration))
            fade.node.volume = fade.from + t * (fade.to - fade.from)
            if t >= 1 {
                fades[key] = nil
                fade.completion?()
            }
        }
    }
}
