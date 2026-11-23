import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// Small pictures of an episode at any second, for the scrub marker.
///
/// libavformat and libavcodec on the loopback URL the player reads, rather
/// than mpv: mpv shows one position at a time, and seeking it would move the
/// episode. Only keyframes are decoded, one packet per picture, in software,
/// so nothing competes for the hardware decoder the episode is using.
///
/// One file stays open between pictures. Opening it reads the header and the
/// index each time. `close()` when the scrub ends: an open reader keeps the
/// torrent fetching ahead of wherever it last read.
final class ScrubFrames: @unchecked Sendable {
    struct Picture: @unchecked Sendable {
        /// The keyframe's own time, at or before the one asked for.
        let time: Double
        let image: CGImage
    }

    static let width: Int32 = 640

    private let queue = DispatchQueue(label: "anicat.scrubframes", qos: .userInitiated)
    // All of these only on `queue`.
    private var url: String?
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var stream: Int32 = -1
    private var deadline = Date.distantFuture

    deinit { tearDown() }

    func picture(url: String, at time: Double) async -> Picture? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.decode(url: url, at: time)) }
        }
    }

    func close() {
        queue.async { self.tearDown() }
    }

    private func decode(url: String, at time: Double) -> Picture? {
        // A read of a piece not downloaded yet blocks inside libavformat.
        deadline = Date().addingTimeInterval(3)
        if self.url != url { tearDown() }
        if format == nil, !open(url) { tearDown(); return nil }
        guard let format, let codec, let source = format.pointee.streams[Int(stream)],
              let packet = av_packet_alloc(), let frame = av_frame_alloc() else { return nil }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        var frameRef: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_packet_free(&packetRef); av_frame_free(&frameRef) }

        let base = source.pointee.time_base
        let target = Int64(time * Double(base.den) / Double(base.num))
        guard av_seek_frame(format, stream, target, AVSEEK_FLAG_BACKWARD) >= 0 else { tearDown(); return nil }
        avcodec_flush_buffers(codec)
        while av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == stream, packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
            // Drained at once: the decoder otherwise holds the picture back
            // for the ones after it.
            guard avcodec_send_packet(codec, packet) >= 0 else { return nil }
            avcodec_send_packet(codec, nil)
            guard avcodec_receive_frame(codec, frame) >= 0, let image = scale(frame) else { return nil }
            let pts = packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts
            return Picture(time: Double(pts) * Double(base.num) / Double(base.den), image: image)
        }
        // Out of time or cut off mid-read: the connection is not one to keep.
        tearDown()
        return nil
    }

    private func open(_ url: String) -> Bool {
        guard let context = avformat_alloc_context() else { return false }
        context.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<ScrubFrames>.fromOpaque(opaque).takeUnretainedValue().deadline < Date() ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        // Frees the context itself on failure.
        guard avformat_open_input(&opened, url, nil, nil) >= 0, let opened else { return false }
        format = opened
        self.url = url
        stream = -1
        for index in 0..<Int(opened.pointee.nb_streams) {
            guard let candidate = opened.pointee.streams[index], let parameters = candidate.pointee.codecpar else { continue }
            // Cover art is a video stream too.
            if stream < 0, parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO, candidate.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 {
                stream = Int32(index)
            } else {
                candidate.pointee.discard = AVDISCARD_ALL
            }
        }
        guard stream >= 0, let parameters = opened.pointee.streams[Int(stream)]?.pointee.codecpar,
              let decoder = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else { return false }
        codec = context
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { return false }
        context.pointee.thread_count = 2
        context.pointee.thread_type = FF_THREAD_SLICE
        // Unseen at this size, and a good part of the decode.
        context.pointee.skip_loop_filter = AVDISCARD_ALL
        return avcodec_open2(context, decoder, nil) >= 0
    }

    private func scale(_ frame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        let source = frame.pointee
        guard source.width > 0, source.height > 0 else { return nil }
        let pixel = source.sample_aspect_ratio
        let aspect = pixel.num > 0 && pixel.den > 0 ? Double(pixel.num) / Double(pixel.den) : 1
        let height = max(Int32(Double(Self.width) * Double(source.height) / (Double(source.width) * aspect)), 2)
        scaler = sws_getCachedContext(
            scaler, source.width, source.height, AVPixelFormat(source.format),
            Self.width, height, AV_PIX_FMT_RGBA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard let scaler else { return nil }
        // swscale assumes BT.601, which turns an HD picture's reds and greens.
        let matrix = source.colorspace == AVCOL_SPC_UNSPECIFIED
            ? (source.height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601) : Int32(source.colorspace.rawValue)
        sws_setColorspaceDetails(
            scaler, sws_getCoefficients(matrix), source.color_range == AVCOL_RANGE_JPEG ? 1 : 0,
            sws_getCoefficients(SWS_CS_DEFAULT), 1, 0, 1 << 16, 1 << 16
        )
        let row = Int(Self.width) * 4
        var pixels = Data(count: row * Int(height))
        let written = pixels.withUnsafeMutableBytes { buffer -> Int32 in
            var planes: [UnsafeMutablePointer<UInt8>?] = [buffer.bindMemory(to: UInt8.self).baseAddress, nil, nil, nil]
            var strides: [Int32] = [Int32(row), 0, 0, 0]
            return withUnsafePointer(to: source.data) { data in
                data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { slices in
                    withUnsafePointer(to: source.linesize) { sizes in
                        sizes.withMemoryRebound(to: Int32.self, capacity: 8) { lines in
                            sws_scale(scaler, slices, lines, 0, source.height, &planes, &strides)
                        }
                    }
                }
            }
        }
        guard written > 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: Int(Self.width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func tearDown() {
        if scaler != nil { sws_freeContext(scaler); scaler = nil }
        avcodec_free_context(&codec)
        avformat_close_input(&format)
        url = nil
        stream = -1
    }
}
