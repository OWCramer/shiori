// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import ArtemisKit
import AVFoundation

/// Artemis sound: one music channel (`splay`/`sstop`/`sfade`/`sxfade`/`span`) and named
/// effect/voice channels (`seplay`/`sestop`/`sefade`/`sepan`), with loops, A-B repeats,
/// fades, pan and 0...1000 gains under the game's master volumes (`s.bgmvol`, `s.sevol`,
/// `s.segain.<id>`). Ogg Vorbis is decoded with ArtemisKit; other formats through AVAudioFile.
@MainActor
final class ArtemisAudio {
    private let output = GameAudioEngine(name: "Artemis")

    /// A playing sound: its tag gain (faded) and pan; the node's volume is gain x master.
    private final class Channel {
        let node: AVAudioPlayerNode
        var gain: Float
        var pan: Float
        var finished = false
        init(node: AVAudioPlayerNode, gain: Float, pan: Float) {
            self.node = node
            self.gain = gain
            self.pan = pan
        }
    }

    private var music: Channel?
    private var effects: [String: Channel] = [:]
    /// Master volume (0...1) for the music (nil) or an effect id, read every frame.
    var masterVolume: @MainActor (String?) -> Float = { _ in 1 }

    func isPlaying(_ id: String) -> Bool {
        guard let channel = effects[id] else { return false }
        return channel.node.isPlaying && !channel.finished
    }

    /// For `get_sound_info`.
    func info(_ id: String?) -> (playing: Bool, gain: Double, pan: Double)? {
        guard let channel = id.map({ effects[$0] }) ?? music else { return (false, 0, 0) }
        return (channel.node.isPlaying && !channel.finished, Double(channel.gain * 1000), Double(channel.pan * 1000))
    }

    var effectIDs: [String] { effects.keys.sorted() }

    private struct Fade {
        let channel: Channel
        let from: Float
        let to: Float
        let pan: Bool
        let began: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (() -> Void)?
    }

    /// Running gain and pan fades, advanced by `tick()` every frame.
    private var fades: [String: Fade] = [:]

    func handle(_ tag: ArtemisTag, data: (String) -> Data?) {
        let gain = tag["gain"].map { _ in tag.number("gain", default: 1000) }
        let pan = tag["pan"].map { _ in tag.number("pan") }
        switch tag.name {
        case "splay", "sfadein":
            stop(music, fadeMs: 0)
            music = play(tag["file"], loop: tag["loop"] != "0", fadeIn: tag.number("time"), gain: gain ?? 1000, pan: pan ?? 0, data: data)
        case "sxfade":
            // The old music fades out while the new one fades in.
            stop(music, fadeMs: tag.number("time"))
            music = play(tag["file"], loop: tag["loop"] != "0", fadeIn: tag.number("time"), gain: gain ?? 1000, pan: pan ?? 0, data: data)
        case "sstop", "sfadeout":
            stop(music, fadeMs: tag.number("time"))
            music = nil
        case "sfade":
            fade(music, to: Float((gain ?? 1000) / 1000), ms: tag.number("time"), key: "music")
        case "span":
            fade(music, to: Float((pan ?? 0) / 1000), ms: tag.number("time"), key: "music.pan", pan: true)
        case "seplay", "voice", "sefadein":
            let id = tag["id"] ?? "0"
            stop(effects[id], fadeMs: 0)
            effects[id] = play(tag["file"], loop: tag["loop"] == "1", fadeIn: tag.number("time"), gain: gain ?? 1000, pan: pan ?? 0, data: data)
        case "sestop", "vstop", "sefadeout":
            let id = tag["id"] ?? "0"
            stop(effects[id], fadeMs: tag.number("time"))
            effects[id] = nil
        case "sefade":
            let id = tag["id"] ?? "0"
            fade(effects[id], to: Float((gain ?? 1000) / 1000), ms: tag.number("time"), key: "se." + id)
        case "sepan":
            let id = tag["id"] ?? "0"
            fade(effects[id], to: Float((pan ?? 0) / 1000), ms: tag.number("time"), key: "se.pan." + id, pan: true)
        default:
            break
        }
    }

    // MARK: Movie sound

    private var stream: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?

    /// Starts a stream for a movie's soundtrack (interleaved stereo floats fed by `enqueue`).
    func startStream(sampleRate: Int) {
        stopStream()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 2, interleaved: false) else { return }
        let node = AVAudioPlayerNode()
        output.attach(node, format: format, resume: .stream)
        node.play()
        stream = node
        streamFormat = format
    }

    func enqueue(_ interleaved: [Float]) {
        guard let node = stream, let format = streamFormat, !interleaved.isEmpty else { return }
        let frames = interleaved.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        for i in 0 ..< frames {
            left[i] = interleaved[2 * i]
            right[i] = interleaved[2 * i + 1]
        }
        node.scheduleBuffer(buffer)
    }

    func stopStream() {
        if let stream { output.detach(stream) }
        stream = nil
        streamFormat = nil
    }

    func stopAll() {
        stopStream()
        stop(music, fadeMs: 0)
        music = nil
        for channel in effects.values { stop(channel, fadeMs: 0) }
        effects.removeAll()
        output.engine.stop()
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

    private func play(_ file: String?, loop: Bool, fadeIn: Double, gain: Double, pan: Double, data: (String) -> Data?) -> Channel? {
        guard let file, !file.isEmpty, let buffer = buffer(file, data: data) else { return nil }
        let node = AVAudioPlayerNode()
        let channel = Channel(node: node, gain: fadeIn > 0 ? 0 : Float(gain / 1000), pan: Float(pan / 1000))
        node.pan = channel.pan
        // A-B repeat: "<name>_a" plays once, then "<name>_b" loops (when it exists).
        if loop, file.hasSuffix("_a"), let loopPart = self.buffer(String(file.dropLast(2)) + "_b", data: data),
           loopPart.format == buffer.format {
            output.attach(node, format: buffer.format, resume: .loop(loopPart))
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            node.scheduleBuffer(loopPart, at: nil, options: [.loops], completionHandler: nil)
        } else if loop {
            output.attach(node, format: buffer.format, resume: .loop(buffer))
            node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        } else {
            let key = ObjectIdentifier(channel)
            // After an audio restart the rest plays on and ends the sound (stopping the node
            // for the restart calls this handler early, so it is ignored then).
            output.attach(node, format: buffer.format, resume: .once(buffer) { [weak self] in self?.markFinished(key) })
            let restart = output.restarts
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.output.restarts == restart else { return }
                    self.markFinished(key)
                }
            }
        }
        node.play()
        if fadeIn > 0 { fade(channel, to: Float(gain / 1000), ms: fadeIn, key: "in." + String(UInt(bitPattern: ObjectIdentifier(channel).hashValue))) }
        apply()
        return channel
    }

    private func markFinished(_ key: ObjectIdentifier) {
        for channel in Array(effects.values) + [music].compactMap({ $0 }) where ObjectIdentifier(channel) == key {
            channel.finished = true
        }
    }

    private func stop(_ channel: Channel?, fadeMs: Double) {
        guard let channel else { return }
        if fadeMs > 0 {
            fade(channel, to: 0, ms: fadeMs, key: "out." + String(UInt(bitPattern: ObjectIdentifier(channel).hashValue))) { [weak self] in
                self?.remove(channel)
            }
        } else {
            remove(channel)
        }
    }

    private func remove(_ channel: Channel) {
        fades = fades.filter { $0.value.channel !== channel }
        output.detach(channel.node)
    }

    private func fade(_ channel: Channel?, to target: Float, ms: Double, key: String, pan: Bool = false, completion: (() -> Void)? = nil) {
        guard let channel else { return }
        guard ms > 0 else {
            fades[key] = nil
            if pan { channel.pan = target } else { channel.gain = target }
            apply()
            completion?()
            return
        }
        fades[key] = Fade(channel: channel, from: pan ? channel.pan : channel.gain, to: target, pan: pan,
                          began: CACurrentMediaTime(), duration: ms / 1000, completion: completion)
    }

    /// Node volumes and pans from the channels' gains and the master volumes.
    private func apply() {
        if let music {
            music.node.volume = music.gain * masterVolume(nil)
            music.node.pan = music.pan
        }
        for (id, channel) in effects {
            channel.node.volume = channel.gain * masterVolume(id)
            channel.node.pan = channel.pan
        }
    }

    /// Advances fades and follows master volume changes; call every frame.
    func tick() {
        let now = CACurrentMediaTime()
        for (key, fade) in fades {
            let t = Float(min(1, (now - fade.began) / fade.duration))
            let value = fade.from + t * (fade.to - fade.from)
            if fade.pan { fade.channel.pan = value } else { fade.channel.gain = value }
            if t >= 1 {
                fades[key] = nil
                fade.completion?()
            }
        }
        apply()
    }
}
