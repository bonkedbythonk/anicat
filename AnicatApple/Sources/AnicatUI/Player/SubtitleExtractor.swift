import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Reads the subtitle events of a stretch of an episode, for `SubtitleGaps`.
///
/// libavformat directly rather than a second headless mpv like
/// `AudioExtractor`: mpv hands subtitles out one line at a time as playback
/// reaches them, and never as a list. The demuxer returns each ASS event as a
/// packet with its time, which is all this needs; nothing is decoded. It
/// reads the same loopback URL the player does, so on a torrent the pieces
/// come through the range server, and they are the same pieces the audio
/// comparison after it reads anyway.
enum SubtitleExtractor {
    struct Track {
        let language: String?
        let header: String
        var lines: [SubtitleGaps.Line] = []
    }

    /// Every ASS track's events between `start` and `start + length`, or nil
    /// when the file could not be read in `timeout`. A file with no ASS track
    /// answers an empty list, not nil.
    static func extract(url: String, start: Double, length: Double, timeout: TimeInterval = 90) async -> [Track]? {
        await Task.detached(priority: .utility) {
            run(url: url, start: start, end: start + length, timeout: timeout)
        }.value
    }

    /// The track to judge by: the English one with the most dialogue. Packs
    /// carry "Signs & Songs" beside "Full Subtitles", and a dub release a
    /// signs-only English track beside other languages' full ones.
    static func dialogueTrack(_ tracks: [Track]) -> (track: Track, dialogue: [(start: Double, end: Double)])? {
        let english = tracks.filter { ["eng", "en"].contains($0.language?.lowercased() ?? "") }
        let pool = english.isEmpty ? tracks : english
        return pool
            .map { ($0, SubtitleGaps.dialogue($0.lines, italicStyles: SubtitleGaps.italicStyles(header: $0.header))) }
            .max { $0.1.count < $1.1.count }
    }

    private static func run(url: String, start: Double, end: Double, timeout: TimeInterval) -> [Track]? {
        guard var context = avformat_alloc_context() else { return nil }
        // A stalled read over HTTP blocks inside libavformat with no
        // deadline of its own; this is what lets it give up. The caller's
        // task chain waits on it, and the ending search queues behind it.
        let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        deadline.pointee = Date().addingTimeInterval(timeout).timeIntervalSince1970
        defer { deadline.deallocate() }
        context.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Date().timeIntervalSince1970 > opaque.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            },
            opaque: UnsafeMutableRawPointer(deadline)
        )
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "20000000", 0)
        defer { av_dict_free(&options) }
        var opened: UnsafeMutablePointer<AVFormatContext>? = context
        guard avformat_open_input(&opened, url, nil, &options) >= 0, let ctx = opened else {
            // `avformat_open_input` frees the context itself on failure.
            return nil
        }
        context = ctx
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }

        var tracks: [Int32: Track] = [:]
        // One audio stream stays on as a clock: with only subtitle packets
        // coming back, a read past a long gap in them would run on until the
        // next line, a minute and a half past the window at an ending.
        var clock: Int32 = -1
        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            let id = par.pointee.codec_id
            if par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE, id == AV_CODEC_ID_ASS || id == AV_CODEC_ID_SSA {
                let header = par.pointee.extradata.map {
                    String(decoding: UnsafeBufferPointer(start: $0, count: Int(par.pointee.extradata_size)), as: UTF8.self)
                } ?? ""
                let language = av_dict_get(stream.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
                tracks[Int32(index)] = Track(language: language, header: header)
            } else if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO, clock < 0 {
                clock = Int32(index)
            } else {
                stream.pointee.discard = AVDISCARD_ALL
            }
        }
        guard !tracks.isEmpty else { return [] }

        if start > 0 {
            av_seek_frame(ctx, -1, Int64(start * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)
        }
        guard let packet = av_packet_alloc() else { return nil }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetRef) }
        var reachedEnd = false
        while av_read_frame(ctx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let index = packet.pointee.stream_index
            guard let stream = ctx.pointee.streams[Int(index)] else { continue }
            let base = stream.pointee.time_base
            let seconds = { (value: Int64) in Double(value) * Double(base.num) / Double(base.den) }
            let pts = packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts
            if index == clock {
                if pts != Int64.min, seconds(pts) > end { reachedEnd = true; break }
                continue
            }
            guard tracks[index] != nil, pts != Int64.min, let data = packet.pointee.data else { continue }
            let lineStart = seconds(pts)
            if lineStart > end { if clock < 0 { reachedEnd = true; break } else { continue } }
            let lineEnd = lineStart + seconds(packet.pointee.duration)
            guard lineEnd > start else { continue }
            // Matroska's ASS packet: ReadOrder, Layer, Style, Name, MarginL,
            // MarginR, MarginV, Effect, Text.
            let raw = String(decoding: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)), as: UTF8.self)
            let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { continue }
            tracks[index]?.lines.append(SubtitleGaps.Line(
                start: lineStart, end: lineEnd, style: String(fields[2]), text: String(fields[8])
            ))
        }
        // Stopped by the deadline, not by the window's end or the file's:
        // what was read is a prefix, and a prefix has no holes it can vouch
        // for.
        if !reachedEnd, Date().timeIntervalSince1970 > deadline.pointee { return nil }
        return tracks.keys.sorted().compactMap { tracks[$0] }
    }
}
