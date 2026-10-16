// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CSiglus
import Foundation

/// The movies Shiori decodes for siglus_rs (`siglus_set_host_media`, siglus.h): Windows Media
/// (ASF with WMV 7/8/9 or VC-1 pictures and WMA 1/2, Pro or Lossless sound, planetarian HD's
/// movie) and MPEG-1/2 video. siglus_rs's own decoders for these are ports of FFmpeg's, which
/// Shiori builds without; the app's LGPL FFmpeg
/// (`Scripts/ffmpeg/build-ios-ffmpeg.sh`) does the decoding instead. The engine reads the
/// file through callbacks and turns the pictures into its own frames; OMV movies stay with the
/// engine (Theora).
enum SiglusMedia {
    /// Registers the decoders with the engine (once, before the first game starts).
    static func register() { _ = registered }

    private static let registered: Void = {
        #if canImport(CFFmpeg)
        var media = SiglusHostMedia(
            version: 1,
            asf_open: siglusAsfOpen,
            asf_next_picture: siglusAsfNextPicture,
            asf_next_sound: siglusAsfNextSound,
            asf_close: siglusAsfClose,
            mpeg_video_open: siglusMpegVideoOpen,
            mpeg_video_send: siglusMpegVideoSend,
            mpeg_video_receive: siglusMpegVideoReceive,
            mpeg_video_close: siglusMpegVideoClose)
        siglus_set_host_media(&media)
        #endif
    }()
}

#if canImport(CFFmpeg)
import CFFmpeg

private let noPTS = Int64.min
private let averrorEOF: Int32 = -0x2046_4F45 // AVERROR_EOF: -MKTAG('E','O','F',' ')
private let averrorAgain: Int32 = -35 // AVERROR(EAGAIN) on Darwin

/// Fills `out` from an 8-bit planar Y'CbCr picture; false for any other layout.
private func describe(_ f: UnsafeMutablePointer<AVFrame>, pts: Int64, into out: UnsafeMutablePointer<SiglusHostPicture>) -> Bool {
    let shift: (UInt32, UInt32)
    switch AVPixelFormat(rawValue: f.pointee.format) {
    case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P: shift = (1, 1)
    case AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUVJ422P: shift = (1, 0)
    case AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUVJ444P: shift = (0, 0)
    default: return false
    }
    guard f.pointee.width > 0, f.pointee.height > 0, let y = f.pointee.data.0, let u = f.pointee.data.1, let v = f.pointee.data.2,
          f.pointee.linesize.0 > 0, f.pointee.linesize.1 > 0, f.pointee.linesize.2 > 0 else { return false }
    out.pointee = SiglusHostPicture(
        width: UInt32(f.pointee.width), height: UInt32(f.pointee.height),
        planes: (UnsafePointer(y), UnsafePointer(u), UnsafePointer(v)),
        strides: (UInt32(f.pointee.linesize.0), UInt32(f.pointee.linesize.1), UInt32(f.pointee.linesize.2)),
        chroma_shift_x: shift.0, chroma_shift_y: shift.1,
        pts: pts,
        key_frame: f.pointee.flags & AV_FRAME_FLAG_KEY != 0 ? 1 : 0)
    return true
}

private func timestamp(_ f: UnsafeMutablePointer<AVFrame>) -> Int64 {
    f.pointee.best_effort_timestamp != noPTS ? f.pointee.best_effort_timestamp : f.pointee.pts
}

// MARK: ASF (WMV and WMA)

/// One ASF movie opened for its pictures or its sound, read through the engine's callbacks.
private final class SiglusAsfMovie {
    let io: SiglusHostIO
    var avio: UnsafeMutablePointer<AVIOContext>?
    var format: UnsafeMutablePointer<AVFormatContext>?
    var codec: UnsafeMutablePointer<AVCodecContext>?
    var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    var streamIndex: Int32 = -1
    var timeBase = AVRational(num: 1, den: 1000)
    /// The movie's start (ms): times are given from it, so they share the duration's origin.
    var startMS: Int64 = 0
    var draining = false
    /// The last sound, interleaved, kept until the next call.
    var sound: [Float] = []

    init(io: SiglusHostIO) { self.io = io }

    deinit {
        av_packet_free(&packet)
        av_frame_free(&frame)
        avcodec_free_context(&codec)
        if format != nil { avformat_close_input(&format) }
        if avio != nil {
            if let buffer = avio?.pointee.buffer { av_free(buffer) }
            avio?.pointee.buffer = nil
            avio_context_free(&avio)
        }
    }

    /// Opens the file and the first stream of the wanted kind; fills `info`.
    func open(want: Int32, info: inout SiglusHostMovieInfo) -> Bool {
        let size = 64 * 1024
        guard packet != nil, frame != nil, let buffer = av_malloc(size)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        avio = avio_alloc_context(buffer, Int32(size), 0, opaque, { opaque, out, count in
            let movie = Unmanaged<SiglusAsfMovie>.fromOpaque(opaque!).takeUnretainedValue()
            let n = movie.io.read?(movie.io.opaque, out, count) ?? -1
            return n > 0 ? n : (n == 0 ? averrorEOF : -5) // AVERROR(EIO)
        }, nil, { opaque, offset, whence in
            let movie = Unmanaged<SiglusAsfMovie>.fromOpaque(opaque!).takeUnretainedValue()
            return movie.io.seek?(movie.io.opaque, offset, whence) ?? -1
        })
        guard let avio else { av_free(buffer); return false }
        format = avformat_alloc_context()
        guard format != nil else { return false }
        format?.pointee.pb = avio
        format?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        // The ASF header describes every stream; no probing decode is needed.
        guard avformat_open_input(&format, nil, av_find_input_format("asf"), nil) == 0, let format else { return false }
        info.duration_ms = format.pointee.duration > 0 ? format.pointee.duration / 1000 : -1
        if format.pointee.start_time != noPTS, format.pointee.start_time > 0 {
            startMS = format.pointee.start_time / 1000
        }
        let wanted = want == 1 ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO
        for i in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[i] else { continue }
            if streamIndex < 0, stream.pointee.codecpar.pointee.codec_type == wanted {
                streamIndex = Int32(i)
            } else {
                stream.pointee.discard = AVDISCARD_ALL
            }
        }
        let found: Int32
        if streamIndex < 0 {
            found = 0
        } else if let stream = format.pointee.streams[Int(streamIndex)], let parameters = stream.pointee.codecpar,
                  let decoder = avcodec_find_decoder(parameters.pointee.codec_id),
                  let context = avcodec_alloc_context3(decoder) {
            codec = context
            timeBase = stream.pointee.time_base
            if avcodec_parameters_to_context(context, parameters) >= 0, avcodec_open2(context, decoder, nil) == 0 {
                found = 1
                info.width = UInt32(max(0, parameters.pointee.width))
                info.height = UInt32(max(0, parameters.pointee.height))
                info.sample_rate = UInt32(max(0, context.pointee.sample_rate))
                info.channels = UInt32(max(0, context.pointee.ch_layout.nb_channels))
            } else {
                avcodec_free_context(&codec)
                found = -1
            }
        } else {
            found = -1
        }
        if want == 1 { info.has_video = found } else { info.has_audio = found }
        if found != 1 {
            SiglusRuntime.log.error("Movie: no \(want == 1 ? "picture" : "sound", privacy: .public) decoder for this ASF stream (\(found))")
        }
        return true
    }

    func milliseconds(_ pts: Int64) -> Int64 {
        guard pts != noPTS else { return noPTS }
        return av_rescale_q(pts, timeBase, AVRational(num: 1, den: 1000)) - startMS
    }

    /// The next decoded frame of the open stream: 1, 0 at the end, negative on error.
    func next() -> Int32 {
        guard let codec, let format, let packet, let frame else { return -1 }
        while true {
            let received = avcodec_receive_frame(codec, frame)
            if received >= 0 { return 1 }
            if received == averrorEOF { return 0 }
            if received != averrorAgain { return received }
            if draining { return 0 }
            if av_read_frame(format, packet) < 0 {
                draining = true
                _ = avcodec_send_packet(codec, nil)
                continue
            }
            if packet.pointee.stream_index == streamIndex {
                // Damaged data is skipped; the decoder carries on from the next packet.
                _ = avcodec_send_packet(codec, packet)
            }
            av_packet_unref(packet)
        }
    }

    func nextPicture(_ out: UnsafeMutablePointer<SiglusHostPicture>) -> Int32 {
        while true {
            let status = next()
            guard status == 1, let frame else { return status }
            if describe(frame, pts: milliseconds(timestamp(frame)), into: out) { return 1 }
        }
    }

    func nextSound(_ out: UnsafeMutablePointer<SiglusHostSound>) -> Int32 {
        while true {
            let status = next()
            guard status == 1, let f = frame else { return status }
            let count = Int(f.pointee.nb_samples), channels = Int(f.pointee.ch_layout.nb_channels)
            guard count > 0, channels > 0, let planes = f.pointee.extended_data else { continue }
            sound.removeAll(keepingCapacity: true)
            sound.reserveCapacity(count * channels)
            let format = AVSampleFormat(rawValue: f.pointee.format)
            let planar = av_sample_fmt_is_planar(format) != 0
            func read<T>(_ type: T.Type, _ convert: (T) -> Float) -> Bool {
                var sources: [UnsafePointer<T>] = []
                for c in 0..<(planar ? channels : 1) {
                    guard let plane = planes[c] else { return false }
                    sources.append(UnsafeRawPointer(plane).assumingMemoryBound(to: T.self))
                }
                if planar {
                    for i in 0..<count { for c in 0..<channels { sound.append(convert(sources[c][i])) } }
                } else {
                    for i in 0..<(count * channels) { sound.append(convert(sources[0][i])) }
                }
                return true
            }
            let ok: Bool
            switch format {
            case AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP: ok = read(Float.self) { $0 }
            case AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P: ok = read(Int16.self) { Float($0) / 32768 }
            case AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P: ok = read(Int32.self) { Float(Double($0) / 2_147_483_648) }
            case AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP: ok = read(Double.self) { Float($0) }
            default: ok = false
            }
            guard ok else { continue }
            out.pointee = sound.withUnsafeBufferPointer { samples in
                SiglusHostSound(samples: samples.baseAddress, frames: UInt32(count), channels: UInt32(channels),
                                sample_rate: UInt32(max(0, f.pointee.sample_rate)), pts_ms: milliseconds(timestamp(f)))
            }
            return 1
        }
    }
}

private func siglusAsfOpen(_ io: UnsafePointer<SiglusHostIO>?, _ want: Int32, _ info: UnsafeMutablePointer<SiglusHostMovieInfo>?) -> UnsafeMutableRawPointer? {
    guard let io, let info else { return nil }
    let movie = SiglusAsfMovie(io: io.pointee)
    var described = SiglusHostMovieInfo(width: 0, height: 0, duration_ms: -1, has_video: 0, has_audio: 0, sample_rate: 0, channels: 0)
    guard movie.open(want: want, info: &described) else {
        SiglusRuntime.log.error("Movie: not an ASF file FFmpeg reads")
        return nil
    }
    info.pointee = described
    return Unmanaged.passRetained(movie).toOpaque()
}

private func siglusAsfNextPicture(_ movie: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<SiglusHostPicture>?) -> Int32 {
    guard let movie, let out else { return -1 }
    return Unmanaged<SiglusAsfMovie>.fromOpaque(movie).takeUnretainedValue().nextPicture(out)
}

private func siglusAsfNextSound(_ movie: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<SiglusHostSound>?) -> Int32 {
    guard let movie, let out else { return -1 }
    return Unmanaged<SiglusAsfMovie>.fromOpaque(movie).takeUnretainedValue().nextSound(out)
}

private func siglusAsfClose(_ movie: UnsafeMutableRawPointer?) {
    guard let movie else { return }
    Unmanaged<SiglusAsfMovie>.fromOpaque(movie).release()
}

// MARK: MPEG-1/2 video

/// An MPEG-1/2 video elementary stream: FFmpeg's parser finds the pictures in the pieces the
/// engine's demuxer sends, and the decoder's pictures wait in order until the engine takes them.
private final class SiglusMpegVideo {
    var parser: UnsafeMutablePointer<AVCodecParserContext>?
    var codec: UnsafeMutablePointer<AVCodecContext>?
    var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    var decoded: [UnsafeMutablePointer<AVFrame>] = []
    /// The picture last handed out, kept until the next call.
    var current: UnsafeMutablePointer<AVFrame>?
    var scratch: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()

    init?() {
        guard packet != nil, scratch != nil, let decoder = avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO),
              let context = avcodec_alloc_context3(decoder) else { return nil }
        codec = context
        guard avcodec_open2(context, decoder, nil) == 0,
              let parser = av_parser_init(Int32(AV_CODEC_ID_MPEG2VIDEO.rawValue)) else { return nil }
        self.parser = parser
    }

    deinit {
        for frame in decoded {
            var owned: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&owned)
        }
        av_frame_free(&current)
        av_frame_free(&scratch)
        av_packet_free(&packet)
        if let parser { av_parser_close(parser) }
        avcodec_free_context(&codec)
    }

    private func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let codec, let scratch else { return }
        // Damaged data is skipped (the decoder resynchronises on the next picture).
        _ = avcodec_send_packet(codec, packet)
        while avcodec_receive_frame(codec, scratch) >= 0 {
            if let copy = av_frame_clone(scratch) { decoded.append(copy) }
            av_frame_unref(scratch)
        }
    }

    func send(_ data: UnsafePointer<UInt8>?, _ length: Int, pts: Int64) -> Int32 {
        guard let parser, let codec, let packet else { return -1 }
        var pts = pts
        var input = data
        var remaining = length
        let draining = data == nil
        repeat {
            var out: UnsafeMutablePointer<UInt8>?
            var outSize: Int32 = 0
            let used = av_parser_parse2(parser, codec, &out, &outSize, input, Int32(min(remaining, Int(Int32.max))), pts, noPTS, -1)
            if used < 0 { return 0 }
            // The time belongs to the first picture starting in this piece (as FFmpeg's demuxer
            // passes it).
            pts = noPTS
            if let base = input { input = base + Int(used) }
            remaining -= Int(used)
            if outSize > 0, let out {
                packet.pointee.data = out
                packet.pointee.size = outSize
                packet.pointee.pts = parser.pointee.pts
                packet.pointee.dts = parser.pointee.dts
                decode(packet)
                packet.pointee.data = nil
                packet.pointee.size = 0
            } else if draining {
                break
            }
        } while remaining > 0 || draining
        if draining { decode(nil) }
        return 0
    }

    func receive(_ out: UnsafeMutablePointer<SiglusHostPicture>) -> Int32 {
        av_frame_free(&current)
        while !decoded.isEmpty {
            current = decoded.removeFirst()
            if let current, describe(current, pts: timestamp(current), into: out) { return 1 }
            av_frame_free(&current)
        }
        return 0
    }
}

private func siglusMpegVideoOpen() -> UnsafeMutableRawPointer? {
    guard let decoder = SiglusMpegVideo() else {
        SiglusRuntime.log.error("Movie: FFmpeg's MPEG video decoder didn't open")
        return nil
    }
    return Unmanaged.passRetained(decoder).toOpaque()
}

private func siglusMpegVideoSend(_ decoder: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ length: Int, _ pts: Int64) -> Int32 {
    guard let decoder else { return -1 }
    return Unmanaged<SiglusMpegVideo>.fromOpaque(decoder).takeUnretainedValue().send(data, length, pts: pts)
}

private func siglusMpegVideoReceive(_ decoder: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<SiglusHostPicture>?) -> Int32 {
    guard let decoder, let out else { return -1 }
    return Unmanaged<SiglusMpegVideo>.fromOpaque(decoder).takeUnretainedValue().receive(out)
}

private func siglusMpegVideoClose(_ decoder: UnsafeMutableRawPointer?) {
    guard let decoder else { return }
    Unmanaged<SiglusMpegVideo>.fromOpaque(decoder).release()
}
#endif
