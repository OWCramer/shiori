import AVFoundation
import CKiriKiri
import CKiriKiriMetal
import Foundation
import os
import UIKit

/// AetherKrkr's runtime: set up once per process, one game open at a time.
@MainActor
enum KiriKiriRuntime {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static let log = Logger(subsystem: "com.owencramer.vnhub", category: "KiriKiri")
    private static var started = false

    /// Opens the game in `gameFolder/base`. Saves go to `saves/`, the engine's logs and cache
    /// to Caches, so `base/` stays as Steam delivered it.
    static func open(gameFolder: URL, appID: UInt32, width: UInt32, height: UInt32) throws -> engine_handle_t {
        if !started {
            guard shiori_krkr_install_services() == ENGINE_RESULT_OK.rawValue else {
                throw Failure(errorDescription: "The KiriKiri runtime didn't start.")
            }
            _ = shiori_krkr_ensure_core(width, height)
            guard shiori_krkr_metal_install() else {
                throw Failure(errorDescription: "Metal isn't available for the KiriKiri renderer.")
            }
            started = true
        }

        // The engine plays through OpenAL, which needs an active playback session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let fileManager = FileManager.default
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        let saves = gameFolder.appendingPathComponent("saves", isDirectory: true)
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KiriKiri/\(gameFolder.lastPathComponent)", isDirectory: true)
        let writable = caches.appendingPathComponent("writable", isDirectory: true)
        let cache = caches.appendingPathComponent("cache", isDirectory: true)
        for folder in [saves, writable, cache] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        setenv("AETHERKIRI_DATA_PATH", saves.path, 1)
        setenv("AETHERKIRI_LOG_DIR", caches.path, 1)
        // A title whose archives use CxDec ships its scheme in the app (KiriKiriSchemes/<appid>.shcx,
        // made with Scripts/kirikiri/garbro-cx.py); the engine decrypts its reads in memory only.
        if let scheme = Bundle.main.url(forResource: String(appID), withExtension: "shcx",
                                        subdirectory: "KiriKiriSchemes") {
            setenv("AETHERKIRI_CX_SCHEME", scheme.path, 1)
        } else {
            unsetenv("AETHERKIRI_CX_SCHEME")
        }
        #if DEBUG
        // Transition and page-swap events in krkr2.log, for comparing a device run with the
        // Mac harness (patch 0012 makes this trace safe on binder layers).
        setenv("AETHERKIRI_TRANS_TRACE", "1", 0)
        // Which timelines E-mote characters are asked to play, and the log written out every
        // second so it can be pulled from a device mid-game.
        setenv("SHIORI_EMOTE_PLAY_TRACE", "1", 0)
        setenv("AETHERKIRI_LOG_FLUSH_SECONDS", "1", 0)
        #endif

        var handle: engine_handle_t?
        let created = writable.path.withCString { writablePath in
            cache.path.withCString { cachePath in
                var desc = engine_create_desc_t()
                desc.struct_size = UInt32(MemoryLayout<engine_create_desc_t>.size)
                desc.api_version = ENGINE_API_VERSION
                desc.writable_path_utf8 = writablePath
                desc.cache_path_utf8 = cachePath
                return engine_create(&desc, &handle)
            }
        }
        guard created == ENGINE_RESULT_OK, let handle else {
            throw Failure(errorDescription: "The KiriKiri engine couldn't be created (\(created.rawValue)).")
        }
        // Render through the GPU bridge (Shiori's Metal host) rather than the CPU fallback.
        setOption(handle, ENGINE_OPTION_RENDERER, ENGINE_RENDERER_GODOT_NATIVE)
        // The first frame comes as the game's own canvas, to learn its size; the view then
        // sizes the surface to the game and goes back to composed frames (useGameSize).
        setOption(handle, ENGINE_OPTION_FRAME_OUTPUT, ENGINE_FRAME_OUTPUT_RAW_SOURCE)
        engine_set_surface_size(handle, width, height)
        let opened = base.path.withCString { engine_open_game(handle, $0, nil) }
        drainLogs(handle)
        guard opened == ENGINE_RESULT_OK else {
            let message = engine_get_last_error(handle).map { String(cString: $0) } ?? ""
            engine_destroy(handle)
            throw Failure(errorDescription: message.isEmpty ? "The game didn't open (\(opened.rawValue))." : message)
        }
        log.notice("Opened \(base.lastPathComponent, privacy: .public) at \(width)x\(height)")
        return handle
    }

    static func close(_ handle: engine_handle_t) {
        drainLogs(handle)
        engine_destroy(handle)
    }

    /// Sizes the surface to the game and returns to composed frames. The raw source isn't
    /// always the finished frame (it can lag behind the composition), so it's only used to
    /// learn the game's size.
    static func useGameSize(_ handle: engine_handle_t, width: UInt32, height: UInt32) {
        engine_set_surface_size(handle, width, height)
        setOption(handle, ENGINE_OPTION_FRAME_OUTPUT, ENGINE_FRAME_OUTPUT_SURFACE)
    }

    private static func setOption(_ handle: engine_handle_t, _ key: String, _ value: String) {
        key.withCString { keyPointer in
            value.withCString { valuePointer in
                var option = engine_option_t()
                option.key_utf8 = keyPointer
                option.value_utf8 = valuePointer
                _ = engine_set_option(handle, &option)
            }
        }
    }

    /// Startup messages (script errors before the window exists end up here).
    static func drainLogs(_ handle: engine_handle_t) {
        var buffer = [CChar](repeating: 0, count: 16384)
        var written: UInt32 = 0
        while engine_drain_startup_logs(handle, &buffer, UInt32(buffer.count - 1), &written) == ENGINE_RESULT_OK,
              written > 0 {
            buffer[Int(written)] = 0
            let text = String(cString: buffer)
            for line in text.split(separator: "\n") where line.contains("error") || line.contains("warning") {
                log.notice("\(line, privacy: .public)")
            }
        }
    }

    /// Requests the game makes of the host: links to open, mostly.
    static func handlePlatformRequests(_ handle: engine_handle_t) {
        var operation = [CChar](repeating: 0, count: 256)
        var argument = [CChar](repeating: 0, count: 8192)
        var available: UInt32 = 0
        while engine_poll_platform_request(handle, &operation, UInt32(operation.count), &argument,
                                           UInt32(argument.count), &available) == ENGINE_RESULT_OK,
              available != 0 {
            let name = String(cString: operation)
            let value = String(cString: argument)
            log.notice("Platform request \(name, privacy: .public)")
            if name == "open_browser", let url = URL(string: value), ["http", "https"].contains(url.scheme) {
                UIApplication.shared.open(url)
            }
        }
    }
}
