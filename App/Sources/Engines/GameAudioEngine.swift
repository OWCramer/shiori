// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import AVFoundation
import UIKit

/// The AVAudioEngine the in-process engines play through (CatSystem2, Luca, Artemis), kept
/// sounding when the audio hardware changes under it: an output that comes and goes (a
/// controller that is also a speaker, headphones, AirPlay), a call or another app's
/// interruption, or iOS resetting its media services. AVAudioEngine stops itself on a
/// configuration change and never starts again on its own, and its player nodes lose what
/// was scheduled on them, so the game went silent until reopened.
///
/// The owner attaches its player nodes here and says what each should do after a restart:
/// a looping sound (music, ambience) is scheduled again from its loop, a one-shot sound (a
/// voice, an effect, a movie's soundtrack) plays on from where it stopped, and a stream (fed
/// as it plays) plays on with what comes next.
@MainActor
final class GameAudioEngine {
    enum Resume {
        /// Schedules the buffer again, looping (the A part of an A-B loop isn't repeated).
        case loop(AVAudioPCMBuffer)
        /// Plays the rest of the buffer, from where it was when the sound stopped; `onEnd`
        /// when the rest has played (not when a later restart stops it).
        case once(AVAudioPCMBuffer, onEnd: (@MainActor () -> Void)? = nil)
        /// Plays on with whatever is scheduled next.
        case stream
    }

    private(set) var engine = AVAudioEngine()
    private let name: String
    private struct Live {
        weak var node: AVAudioPlayerNode?
        var format: AVAudioFormat
        var resume: Resume?
        /// Seconds of a `.once` sound skipped when it was resumed (the node's own time starts
        /// again at the resume).
        var offset: Double = 0
        /// When the node last started playing (the wall clock stands in for its own time once
        /// the engine has stopped).
        var started = CACurrentMediaTime()
    }

    /// Seconds of a one-shot sound played before its node's latest start (0 unless the sound
    /// was resumed after a restart): add the node's own time for the place in the sound.
    func offset(of node: AVAudioPlayerNode) -> Double { live[ObjectIdentifier(node)]?.offset ?? 0 }

    private var live: [ObjectIdentifier: Live] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    /// The engine's own configuration changes (a new engine after a reset has its own).
    nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?
    /// Counts restarts. Stopping a node calls its buffers' completion handlers, so a
    /// handler that marks a sound finished checks this hasn't changed since it was scheduled.
    private(set) var restarts = 0
    private var closed = false
    private var recovering = false

    var mainMixerNode: AVAudioMixerNode { engine.mainMixerNode }

    init(name: String) {
        self.name = name
        Self.activateSession()
        observe()
        #if DEBUG
        scheduleDrill()
        #endif
    }

    deinit {
        for observer in observers + [configurationObserver].compactMap(\.self) { NotificationCenter.default.removeObserver(observer) }
    }

    static func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Attaches a player node for a sound in `format`, starting the engine if it isn't.
    func attach(_ node: AVAudioPlayerNode, format: AVAudioFormat, resume: Resume? = nil) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        live[ObjectIdentifier(node)] = Live(node: node, format: format, resume: resume)
        startIfNeeded()
    }

    func detach(_ node: AVAudioPlayerNode) {
        node.stop()
        live[ObjectIdentifier(node)] = nil
        if node.engine === engine { engine.detach(node) }
    }

    /// The game is left: everything stops and nothing restarts.
    func close() {
        closed = true
        for entry in live.values { entry.node?.stop() }
        live.removeAll()
        engine.stop()
        for observer in observers + [configurationObserver].compactMap(\.self) { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        configurationObserver = nil
    }

    private func startIfNeeded() {
        guard !closed, !engine.isRunning else { return }
        do { try engine.start() } catch {
            NSLog("%@", "\(self.name): the audio engine didn't start: \(String(describing: error))")
        }
    }

    // MARK: Recovering

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observeConfiguration()
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.recover("route change (\(reason.map { String(describing: $0.rawValue) } ?? "?"))", rebuild: false, force: false) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.recover("interruption ended", rebuild: false, force: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover("media services reset", rebuild: true, force: true) }
        })
        // Coming back to the app: anything a missed notification left stopped.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover("back in front", rebuild: false, force: false) }
        })
    }

    private func observeConfiguration() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover("configuration change", rebuild: false, force: true) }
        }
    }

    /// Restarts the engine (a new one after a media services reset) and the sounds that
    /// should go on. `force` restarts the nodes even where the engine reports running (a
    /// configuration change has already stopped them).
    private func recover(_ reason: String, rebuild: Bool, force: Bool) {
        guard !closed, !recovering else { return }
        live = live.filter { $0.value.node != nil }
        guard force || rebuild || !engine.isRunning else { return }
        guard !live.isEmpty || rebuild else {
            NSLog("%@", "\(self.name): \(reason), nothing playing")
            return
        }
        recovering = true
        defer { recovering = false }
        restarts += 1
        Self.activateSession()
        let volume = engine.mainMixerNode.outputVolume
        // Where each one-shot sound had got to (the node's time stops with the engine).
        var played: [ObjectIdentifier: Double] = [:]
        let now = CACurrentMediaTime()
        for (key, entry) in live {
            guard case .once = entry.resume, let node = entry.node else { continue }
            if let render = node.lastRenderTime, render.isSampleTimeValid, let time = node.playerTime(forNodeTime: render),
               time.sampleRate > 0, time.sampleTime > 0 {
                played[key] = entry.offset + Double(time.sampleTime) / time.sampleRate
            } else {
                // A sound that would have ended by now isn't played again.
                played[key] = entry.offset + (now - entry.started)
            }
        }
        let entries = Array(live)
        // A stream keeps what was queued on it (stopping would drop it and end its sound).
        for (_, entry) in entries {
            if case .stream = entry.resume { continue }
            entry.node?.stop()
        }
        if rebuild {
            let old = engine
            old.stop()
            for (_, entry) in entries { if let node = entry.node, node.engine === old { old.detach(node) } }
            engine = AVAudioEngine()
            observeConfiguration()
            for (_, entry) in entries {
                guard let node = entry.node else { continue }
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: entry.format)
            }
        } else {
            engine.stop()
            // The new output's format.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        }
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        startIfNeeded()
        var resumed = 0
        for (key, entry) in entries {
            guard let node = entry.node else { continue }
            switch entry.resume {
            case .loop(let buffer):
                live[key]?.started = CACurrentMediaTime()
                node.scheduleBuffer(buffer, at: nil, options: .loops)
                node.play()
                resumed += 1
            case .once(let buffer, let onEnd):
                let rate = buffer.format.sampleRate
                let seconds = min(max(played[key] ?? .infinity, 0), Double(buffer.frameLength) / rate)
                let from = AVAudioFramePosition(seconds * rate)
                guard from < AVAudioFramePosition(buffer.frameLength) - 64, let rest = Self.slice(buffer, from: from) else {
                    onEnd?()
                    continue
                }
                live[key]?.offset = Double(from) / rate
                live[key]?.started = CACurrentMediaTime()
                let restart = restarts
                node.scheduleBuffer(rest, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let onEnd else { return }
                    Task { @MainActor in
                        guard let self, self.restarts == restart else { return }
                        onEnd()
                    }
                }
                node.play()
                resumed += 1
            case .stream:
                node.play()
                resumed += 1
            case nil:
                break
            }
        }
        NSLog("%@", "\(self.name): \(reason): engine \(self.engine.isRunning ? "running" : "stopped"), \(resumed) of \(entries.count) sounds resumed")
    }

    /// The buffer from a frame on.
    private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let start = max(0, Int(start))
        let count = Int(buffer.frameLength) - start
        guard count > 0, let source = buffer.floatChannelData,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let target = rest.floatChannelData else { return nil }
        rest.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + start, count: count)
        }
        return rest
    }

    #if DEBUG
    /// `-ShioriAudioDrill "8:config;14:route;20:interrupt;26:reset"`: at seconds from the
    /// engine's start, what iOS does to it on a configuration change (stops it, then posts),
    /// a route change, an interruption (began, ended a second later) and a media services
    /// reset, to check that sound comes back in the simulator.
    private func scheduleDrill() {
        let script = UserDefaults.standard.string(forKey: "ShioriAudioDrill") ?? ""
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let kind = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.closed else { return }
                let center = NotificationCenter.default
                let session = AVAudioSession.sharedInstance()
                NSLog("%@", "\(self.name): drill \(kind)")
                switch kind {
                case "config":
                    self.engine.stop()
                    center.post(name: .AVAudioEngineConfigurationChange, object: self.engine)
                case "route":
                    self.engine.stop()
                    center.post(name: AVAudioSession.routeChangeNotification, object: session,
                                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                case "interrupt":
                    self.engine.pause()
                    center.post(name: AVAudioSession.interruptionNotification, object: session,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        center.post(name: AVAudioSession.interruptionNotification, object: session,
                                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                               AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
                    }
                case "reset":
                    self.engine.stop()
                    center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: session)
                default:
                    break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    let playing = self.live.values.filter { $0.node?.isPlaying == true }.count
                    NSLog("%@", "\(self.name): after drill \(kind): engine \(self.engine.isRunning ? "running" : "stopped"), \(playing) of \(self.live.count) nodes playing")
                }
            }
        }
    }
    #endif
}

/// For an engine that plays through its own output (Siglus: kira over a RemoteIO unit): says
/// when the output may need starting again (an interruption ended, the route changed, media
/// services were reset), after making the session active again.
@MainActor
final class AudioOutputWatcher {
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(name: String, restart: @escaping @MainActor (String) -> Void) {
        GameAudioEngine.activateSession()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let handle: @MainActor (String) -> Void = { reason in
            GameAudioEngine.activateSession()
            NSLog("%@", "\(name): \(reason), restarting the audio output")
            restart(reason)
        }
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Only an output that came or went (or was overridden); category changes are the
            // session's own.
            guard let reason, [.newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange].contains(reason) else { return }
            MainActor.assumeIsolated { handle("route change (\(reason.rawValue))") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            MainActor.assumeIsolated { handle("interruption ended") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { handle("media services reset") }
        })
        #if DEBUG
        // `-ShioriAudioDrill "8:route;14:interrupt;20:reset"`: the notifications iOS sends.
        for step in (UserDefaults.standard.string(forKey: "ShioriAudioDrill") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let kind = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self != nil else { return }
                NSLog("%@", "\(name): drill \(kind)")
                switch kind {
                case "route", "config":
                    center.post(name: AVAudioSession.routeChangeNotification, object: session,
                                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                case "interrupt":
                    center.post(name: AVAudioSession.interruptionNotification, object: session,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
                    center.post(name: AVAudioSession.interruptionNotification, object: session,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
                case "reset":
                    center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: session)
                default:
                    break
                }
            }
        }
        #endif
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
