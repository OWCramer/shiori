// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import ArtemisKit
import AVFoundation
import CatSystemKit

/// CatSystem2 sound: one music track (looping), one voice, numbered effect channels, and the
/// system screens' own sounds. Every sound is Ogg Vorbis in the game's archives (`bgm.int`,
/// `se.int`, `pcm_*.int`), found by name and decoded with ArtemisKit's stb_vorbis off the
/// main thread (ambient loops run to 17 MB), then played in memory.
@MainActor
final class CatSystemAudio {
    private let output = GameAudioEngine(name: "CatSystem")
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
    /// The system screens' sounds (channels `sys-…`).
    var systemVolume: Float = 0.8

    private func volume(forEffect channel: String) -> Float {
        channel.hasPrefix("sys-") ? systemVolume : effectVolume
    }

    /// The CONFIG's per-character voice volume for a voice file (0…1).
    var voiceLevel: (String) -> Float = { _ in 1 }

    /// Takes new volumes (the CONFIG screen) for what is playing now too; `master` scales
    /// everything.
    func setVolumes(master: Float = 1, music: Float, voice: Float, effects: Float, system: Float) {
        output.mainMixerNode.outputVolume = master
        musicVolume = music
        voiceVolume = voice
        effectVolume = effects
        systemVolume = system
        fades.removeAll { !$0.stop }
        self.music?.volume = music
        self.voice?.volume = voice * (voiceName.map(voiceLevel) ?? 1)
        for (channel, node) in self.effects {
            node.volume = volume(forEffect: channel) * (effectLevels[channel]?.to ?? 1)
        }
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
            self.voice = self.play(buffer, loop: false, volume: self.voiceVolume * self.voiceLevel(name), fadeFrames: 0)
            NSLog("CatSystem: voice %@ (%.1f s)", name, Double(buffer.frameLength) / buffer.format.sampleRate)
            self.voiceStarted = CACurrentMediaTime()
            self.voiceName = name
            // Its loudness per 1/60 s, for the mouths of voices without `.lv` levels.
            if let samples = buffer.floatChannelData?[0] {
                self.voiceEnvelope = EmoteStage.envelope(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)),
                                                         rate: buffer.format.sampleRate)
            }
            self.voiceEnds = CACurrentMediaTime() + Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    /// The voice playing and when it began (for lip sync).
    private(set) var voiceName: String?
    private(set) var voiceStarted: CFTimeInterval = 0
    /// The voice's loudness (RMS) per 1/60 s.
    private(set) var voiceEnvelope: [Float] = []

    func stopVoice() {
        _ = request("voice")
        stop(voice, frames: 0)
        voice = nil
        voiceEnds = 0
        voiceName = nil
        voiceEnvelope = []
    }

    /// A sound effect on a channel (`se 0 se2041`, or a system screen's `se1`).
    func playEffect(_ name: String, channel: String, loop: Bool = false, game: CatSystemGame) {
        stop(effects[channel], frames: 0)
        // A new sound on the channel starts at the channel's level, without its old fade.
        if let level = effectLevels[channel] { effectLevels[channel] = (0, nil, level.to) }
        effects[channel] = nil
        let ticket = request("se" + channel)
        decode(name, game: game) { [weak self] buffer in
            guard let self, self.requested["se" + channel] == ticket, let buffer else { return }
            let level = self.effectLevels[channel]
            let base = self.volume(forEffect: channel)
            let node = self.play(buffer, loop: loop, volume: base * (level?.from ?? level?.to ?? 1), fadeFrames: 0)
            self.effects[channel] = node
            if let level, let node, level.frames > 0 {
                self.fades.append((node, node.volume, base * level.to, CACurrentMediaTime(), Double(level.frames) / 60, false))
            }
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

    /// A channel's level (0–1, times the effects volume) as `se N fade`/`vol` set it, kept for
    /// the channel's next sound too (an effect still decoding fades in once it starts).
    private var effectLevels: [String: (frames: Int, from: Float?, to: Float)] = [:]

    func fadeEffect(_ channel: String, frames: Int, from: Float?, to: Float) {
        effectLevels[channel] = (frames, from, to)
        guard let node = effects[channel] else { return }
        effectLevels[channel] = (0, nil, to)
        fades.removeAll { $0.node === node }
        let base = volume(forEffect: channel)
        if frames > 0 {
            let start = from.map { base * $0 } ?? node.volume
            fades.append((node, start, base * to, CACurrentMediaTime(), Double(frames) / 60, false))
        } else {
            node.volume = base * to
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
        effectLevels.removeAll()
        fades.removeAll()
        output.engine.stop()
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
