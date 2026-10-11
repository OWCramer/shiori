import ArtemisKit
import AVFoundation
import CatSystemKit

/// CatSystem2 sound: one music track (looping), one voice, numbered effect channels, and the
/// system screens' own sounds. Every sound is Ogg Vorbis in the game's archives (`bgm.int`,
/// `se.int`, `pcm_*.int`), found by name and decoded with ArtemisKit's stb_vorbis off the
/// main thread (ambient loops run to 17 MB), then played in memory.
@MainActor
final class CatSystemAudio {
    private let engine = AVAudioEngine()
    private let decoder = DispatchQueue(label: "catsystem.audio", qos: .userInitiated)
    private var music: AVAudioPlayerNode?
    private var musicName: String?
    private var voice: AVAudioPlayerNode?
    private var effects: [String: AVAudioPlayerNode] = [:]
    /// What each channel asked for last, so a decode that finishes late doesn't play over a
    /// newer request.
    private var requested: [String: Int] = [:]
    private var generation = 0
    private var fades: [(node: AVAudioPlayerNode, from: Float, to: Float, start: CFTimeInterval, duration: CFTimeInterval, stop: Bool)] = []
    private var musicCache: [String: AVAudioPCMBuffer] = [:]
    private var voiceEnds: CFTimeInterval = 0
    var musicVolume: Float = 0.7
    var voiceVolume: Float = 1
    var effectVolume: Float = 0.8

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var isVoicePlaying: Bool { voice != nil && CACurrentMediaTime() < voiceEnds }

    func playMusic(_ name: String, game: CatSystemGame, fadeFrames: Int = 0) {
        guard name.lowercased() != musicName?.lowercased() || music == nil else { return }
        stop(music, frames: 30)
        music = nil
        musicName = name
        let ticket = request("music")
        if let cached = musicCache[name.lowercased()] {
            music = play(cached, loop: true, volume: musicVolume, fadeFrames: fadeFrames)
            return
        }
        decode(name, game: game) { [weak self] buffer in
            guard let self, self.requested["music"] == ticket, let buffer else { return }
            self.musicCache[name.lowercased()] = buffer
            if self.musicCache.count > 4, let old = self.musicCache.keys.first(where: { $0 != name.lowercased() }) {
                self.musicCache.removeValue(forKey: old)
            }
            self.music = self.play(buffer, loop: true, volume: self.musicVolume, fadeFrames: fadeFrames)
            NSLog("CatSystem: music %@", name)
        }
    }

    func stopMusic(fadeFrames: Int) {
        _ = request("music")
        stop(music, frames: fadeFrames)
        music = nil
        musicName = nil
    }

    func playVoice(_ name: String, game: CatSystemGame) {
        stopVoice()
        let ticket = request("voice")
        decode(name, game: game) { [weak self] buffer in
            guard let self, self.requested["voice"] == ticket, let buffer else { return }
            self.voice = self.play(buffer, loop: false, volume: self.voiceVolume, fadeFrames: 0)
            NSLog("CatSystem: voice %@ (%.1f s)", name, Double(buffer.frameLength) / buffer.format.sampleRate)
            self.voiceStarted = CACurrentMediaTime()
            self.voiceName = name
            self.voiceEnds = CACurrentMediaTime() + Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    /// The voice playing and when it began (for lip sync).
    private(set) var voiceName: String?
    private(set) var voiceStarted: CFTimeInterval = 0

    func stopVoice() {
        _ = request("voice")
        stop(voice, frames: 0)
        voice = nil
        voiceEnds = 0
        voiceName = nil
    }

    /// A sound effect on a channel (`se 0 se2041`, or a system screen's `se1`).
    func playEffect(_ name: String, channel: String, loop: Bool = false, game: CatSystemGame) {
        stop(effects[channel], frames: 0)
        effects[channel] = nil
        let ticket = request("se" + channel)
        decode(name, game: game) { [weak self] buffer in
            guard let self, self.requested["se" + channel] == ticket, let buffer else { return }
            let node = self.play(buffer, loop: loop, volume: self.effectVolume, fadeFrames: 0)
            self.effects[channel] = node
            if !loop, let node {
                let length = Double(buffer.frameLength) / buffer.format.sampleRate
                DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.3) { [weak self] in
                    guard let self, self.effects[channel] === node else { return }
                    self.detach(node)
                    self.effects[channel] = nil
                }
            }
        }
    }

    /// Stops one channel, or every effect when `channel` is nil.
    func stopEffect(_ channel: String?, fadeFrames: Int) {
        if let channel {
            _ = request("se" + channel)
            stop(effects[channel], frames: fadeFrames)
            effects[channel] = nil
        } else {
            for key in effects.keys { _ = request("se" + key) }
            for node in effects.values { stop(node, frames: fadeFrames) }
            effects.removeAll()
        }
    }

    /// Advances fades; call every frame.
    func tick() {
        let now = CACurrentMediaTime()
        fades = fades.filter { fade in
            let t = Float(min(1, (now - fade.start) / max(fade.duration, 0.001)))
            fade.node.volume = fade.from + (fade.to - fade.from) * t
            if t >= 1 {
                if fade.stop { detach(fade.node) }
                return false
            }
            return true
        }
    }

    func stopAll() {
        generation += 1
        requested.removeAll()
        for node in [music, voice].compactMap({ $0 }) + Array(effects.values) { detach(node) }
        for fade in fades { detach(fade.node) }
        music = nil
        musicName = nil
        voice = nil
        voiceName = nil
        effects.removeAll()
        fades.removeAll()
        engine.stop()
    }

    private func request(_ channel: String) -> Int {
        generation += 1
        requested[channel] = generation
        return generation
    }

    private func decode(_ name: String, game: CatSystemGame, then body: @escaping @MainActor (AVAudioPCMBuffer?) -> Void) {
        let file = name.lowercased().hasSuffix(".ogg") ? name : name + ".ogg"
        decoder.async {
            let bytes = (try? game.file(named: file)) ?? nil
            let buffer = bytes.flatMap { Self.buffer(Data($0)) }
            if bytes == nil { NSLog("CatSystem: no sound %@", file) }
            DispatchQueue.main.async { MainActor.assumeIsolated { body(buffer) } }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, loop: Bool, volume: Float, fadeFrames: Int) -> AVAudioPlayerNode? {
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [])
        if fadeFrames > 0 {
            node.volume = 0
            fades.append((node, 0, volume, CACurrentMediaTime(), Double(fadeFrames) / 60, false))
        } else {
            node.volume = volume
        }
        node.play()
        return node
    }

    private func stop(_ node: AVAudioPlayerNode?, frames: Int) {
        guard let node else { return }
        fades.removeAll { $0.node === node }
        if frames > 0 {
            fades.append((node, node.volume, 0, CACurrentMediaTime(), Double(frames) / 60, true))
        } else {
            detach(node)
        }
    }

    private func detach(_ node: AVAudioPlayerNode) {
        node.stop()
        if node.engine != nil { engine.detach(node) }
    }

    nonisolated private static func buffer(_ data: Data) -> AVAudioPCMBuffer? {
        guard let pcm = decodeOggVorbis(data), pcm.channels > 0, pcm.frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(pcm.sampleRate), channels: AVAudioChannelCount(pcm.channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        let channels = pcm.channels
        pcm.samples.withUnsafeBufferPointer { samples in
            for c in 0..<channels {
                guard let out = buffer.floatChannelData?[c] else { continue }
                for f in 0..<pcm.frameCount { out[f] = Float(samples[f * channels + c]) / 32768 }
            }
        }
        return buffer
    }
}
