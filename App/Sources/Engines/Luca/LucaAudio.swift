import ArtemisKit
import AVFoundation
import LucaKit

/// Luca System sound: one music track (looping), one voice, and numbered effect channels.
/// Everything is Ogg Vorbis inside the game's PAKs, decoded with ArtemisKit's stb_vorbis.
@MainActor
final class LucaAudio {
    private let output = GameAudioEngine(name: "Luca")
    private var music: AVAudioPlayerNode?
    private var musicID: Int?
    private var voice: AVAudioPlayerNode?
    private var effects: [Int: AVAudioPlayerNode] = [:]
    private var fades: [(node: AVAudioPlayerNode, from: Float, to: Float, start: CFTimeInterval, duration: CFTimeInterval, stop: Bool)] = []
    /// Decoded music, so a track that comes back doesn't decode again.
    private var musicCache: [Int: AVAudioPCMBuffer] = [:]
    /// The script's own volume for each effect channel, scaled by `effectVolume`.
    private var effectLevels: [Int: Float] = [:]
    var musicVolume: Float = 0.8 {
        didSet { if let music, !fades.contains(where: { $0.node === music }) { music.volume = musicVolume } }
    }
    var voiceVolume: Float = 1 {
        didSet { voice?.volume = voiceVolume * voiceLevel }
    }
    /// The speaking character's own level (OPTIONS › Voice), for the next voice.
    var nextVoiceLevel: Float = 1
    private var voiceLevel: Float = 1
    var effectVolume: Float = 0.9 {
        didSet {
            for (channel, node) in effects where !fades.contains(where: { $0.node === node }) {
                node.volume = effectVolume * (effectLevels[channel] ?? 1)
            }
        }
    }
    var systemVolume: Float = 0.9

    /// When the voice on now ends (a player node still reports playing after its buffer ends).
    private var voiceEnds: CFTimeInterval = 0
    var isVoicePlaying: Bool { voice != nil && CACurrentMediaTime() < voiceEnds }

    func handle(_ sound: LucaSound, game: LucaGame) {
        switch sound {
        case .music(let id, let fade):
            guard id != musicID || music == nil else { return }
            stop(music, frames: 30)
            musicID = id
            guard let buffer = musicCache[id] ?? game.music(id).flatMap(Self.buffer) else { music = nil; return }
            musicCache[id] = buffer
            if musicCache.count > 6, let old = musicCache.keys.first(where: { $0 != id }) { musicCache.removeValue(forKey: old) }
            music = play(buffer, loop: true, volume: musicVolume, fadeFrames: fade)
        case .stopMusic(let fade):
            stop(music, frames: fade)
            music = nil
            musicID = nil
        case .effect(let channel, let id, let loop, let volume, let fade):
            stop(effects[channel], frames: 0)
            guard let buffer = game.soundEffect(id).flatMap(Self.buffer) else { effects[channel] = nil; return }
            effectLevels[channel] = Float(volume)
            effects[channel] = play(buffer, loop: loop, volume: effectVolume * Float(volume), fadeFrames: fade)
        case .stopEffect(let channel, let fade):
            if channel < 0 {
                for node in effects.values { stop(node, frames: fade) }
                effects.removeAll()
            } else {
                stop(effects[channel], frames: fade)
                effects[channel] = nil
            }
        case .voice(let id):
            stop(voice, frames: 0)
            guard let buffer = game.voice(id).flatMap(Self.buffer) else { voice = nil; return }
            voiceLevel = nextVoiceLevel
            voice = play(buffer, loop: false, volume: voiceVolume * voiceLevel, fadeFrames: 0)
            voiceEnds = CACurrentMediaTime() + Double(buffer.frameLength) / buffer.format.sampleRate
        case .stopVoice:
            stop(voice, frames: 0)
            voice = nil
        }
    }

    private var movieNode: AVAudioPlayerNode?
    private var movieStart: CFTimeInterval?

    /// A movie's soundtrack; `movieTime` follows it.
    func playMovie(_ buffer: AVAudioPCMBuffer) {
        stopMovie()
        movieNode = play(buffer, loop: false, volume: 1, fadeFrames: 0)
        movieStart = CACurrentMediaTime()
    }

    func stopMovie() {
        if let movieNode { detach(movieNode) }
        movieNode = nil
        movieStart = nil
    }

    /// Seconds into the movie's soundtrack.
    var movieTime: Double? {
        guard let node = movieNode, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return movieStart.map { CACurrentMediaTime() - $0 } }
        return output.offset(of: node) + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    nonisolated static func movieBuffer(_ ogg: Data) -> AVAudioPCMBuffer? { buffer(ogg) }

    /// A sound from SYSSE.PAK (title_hit, TOGGLE, …).
    func playSystem(_ name: String, game: LucaGame) {
        guard let buffer = game.systemSound(named: name).flatMap(Self.buffer) else { return }
        let node = play(buffer, loop: false, volume: systemVolume, fadeFrames: 0)
        // Detached when done.
        if let node {
            let length = Double(buffer.frameLength) / buffer.format.sampleRate
            DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.2) { [weak self] in self?.detach(node) }
        }
    }

    /// Plays a line's voice again (the window's VOICE button).
    func replayVoice(_ id: Int, level: Float = 1, game: LucaGame) {
        nextVoiceLevel = level
        handle(.voice(id: id), game: game)
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
        for node in [music, voice].compactMap({ $0 }) + Array(effects.values) { detach(node) }
        music = nil
        musicID = nil
        voice = nil
        effects.removeAll()
        fades.removeAll()
        output.engine.stop()
    }

    private func play(_ buffer: AVAudioPCMBuffer, loop: Bool, volume: Float, fadeFrames: Int) -> AVAudioPlayerNode? {
        let node = AVAudioPlayerNode()
        output.attach(node, format: buffer.format, resume: loop ? .loop(buffer) : .once(buffer))
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
        output.detach(node)
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
