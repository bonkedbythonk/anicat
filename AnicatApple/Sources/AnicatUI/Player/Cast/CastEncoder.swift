#if os(macOS)
import Foundation
import Libmpv

/// Upscales and encodes the playing episode for the TV with a second,
/// headless libmpv in encoding mode: Anime4K through FFmpeg's `libplacebo`
/// filter, subtitles burned in at 4K, VideoToolbox HEVC, no audio (the
/// sound stays on the Mac).
///
/// mpv's own `glsl-shaders` do nothing here: encoding mode has no GPU
/// renderer, so the chain has to run as a video filter. The libplacebo
/// filter, MoltenVK and `hevc_videotoolbox` are all in MPVKit already.
/// Measured on an M4 Pro, 1080p HEVC BluRay source: 60 s of video in 27 s,
/// so the encode stays ahead of the TV with room to spare.
///
/// The output is fragmented MP4 written as it goes, so the stream server
/// can hand the TV the first fragments while the rest is still encoding.
/// Its timestamps start at 0 whatever `start` was; `CastSession` keeps the
/// offset.
final class CastEncoder: @unchecked Sendable {
    struct Job: Sendable {
        let url: String
        let start: Double
        let output: URL
        /// mpv's track id, or nil for no subtitles.
        let subtitleId: String?
        /// The player's audio track id when the sound plays on the TV; nil
        /// keeps the stream silent for sound on the Mac.
        let audioId: String?
        /// The player's own computed overrides and `sub-*` look, so the TV
        /// shows the subtitles the Mac would have.
        let subtitleOptions: [(String, String)]
        /// Nil without an upscale (Anime4K off, live action, a 2160p
        /// source): the TV's own scaler handles those.
        let videoFilter: String?
        let fps: Double
        /// Video bitrate in Mb/s; `CastSession` lowers it when the TV's
        /// Wi-Fi cannot keep up.
        let megabits: Int
    }

    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    /// True once mpv has written the whole stretch (or failed): the server
    /// ends the response instead of waiting for more bytes.
    var isFinished: Bool { lock.withLock { finished } }

    func cancel() { lock.withLock { cancelled = true } }

    /// Episode time the encode may run up to before it pauses. `CastSession`
    /// keeps moving it to a minute past the TV's position, and the server
    /// past any segment the TV asks for; it only grows, so neither undoes
    /// the other.
    private var encodeUntil: Double?
    func setLimit(_ seconds: Double) { lock.withLock { encodeUntil = max(encodeUntil ?? seconds, seconds) } }

    /// Frames per GOP, which is also one HLS segment: two seconds, so the
    /// TV can start or recover on any of them.
    static func gop(fps: Double) -> Int { Int((fps > 0 ? fps : 24) * 2) }

    /// mpv's position in the source while encoding, for the lead measurement.
    var position: Double { lock.withLock { lastPosition } }
    private var lastPosition: Double = 0

    private static func doubleProperty(_ mpv: OpaquePointer, _ name: String) -> Double? {
        var value: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func start(_ job: Job) {
        Thread.detachNewThread { [self] in
            run(job)
            lock.withLock { finished = true }
            // Deleted here, after mpv has let go of it, and not by the
            // session when it cancels: mpv creates the output on the first
            // encoded frame, so a seek within a second of the previous one
            // deleted a file mpv had not made yet, which mpv then made and
            // left behind.
            if lock.withLock({ cancelled }) {
                try? FileManager.default.removeItem(at: job.output)
            }
        }
    }

    private func run(_ job: Job) {
        guard let mpv = mpv_create() else { return }
        defer { mpv_terminate_destroy(mpv) }
        // The TV can only start decoding on a keyframe, and every segment
        // the server cuts is one GOP.
        let gop = Self.gop(fps: job.fps)
        var options: [(String, String)] = [
            ("config", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("load-scripts", "no"),
            ("input-default-bindings", "no"),
            ("aid", "no"),
            ("sid", job.subtitleId ?? "no"),
            // Precise start: the output's 0 has to be exactly `start` or the
            // Mac's audio is off by however far a keyframe seek landed.
            ("hr-seek", "yes"),
            ("start", String(format: "%.3f", max(job.start, 0))),
            ("o", job.output.path),
            ("of", "mp4"),
            // empty_moov: the header goes out before any frame exists, which
            // is what lets the TV start on a file that is still growing.
            ("ofopts", "movflags=frag_keyframe+empty_moov+default_base_moof"),
            ("ovc", "hevc_videotoolbox"),
            // `b` alone is an average: a pan in Pseudo Harem ep 5 at 10:13
            // spent 39 Mb/s for a second and 17-34 for three more, over the
            // 25 Mb/s that level 5.0 (the hev1 L150 the TV is told) allows,
            // and the TV stuttered 1-3 s into pans. Capped, the same pan
            // peaks at 15.
            ("ovcopts", "b=\(job.megabits)M,maxrate=\(job.megabits * 8 / 5)M,bufsize=\(job.megabits * 8 / 5)M,g=\(gop)"),
        ]
        if let audio = job.audioId {
            // AAC stereo: every receiver decodes it, where a 5.1 or Opus
            // track from the release may play silent on one.
            options += [("aid", audio), ("oac", "aac"), ("oacopts", "b=192k"), ("audio-channels", "stereo")]
        }
        if let filter = job.videoFilter { options.append(("vf", filter)) }
        options += job.subtitleOptions
        for (name, value) in options {
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else {
            AppLog.write("[cast] encoder init failed")
            return
        }
        // A filter graph mpv cannot build only says "no audio or video data
        // played" at the end; the reason is in its warnings.
        mpv_request_log_messages(mpv, "warn")
        var args: [UnsafePointer<CChar>?] = ["loadfile", job.url].map { UnsafePointer(strdup($0)) }
        args.append(nil)
        defer { args.forEach { $0.map { free(UnsafeMutableRawPointer(mutating: $0)) } } }
        guard args.withUnsafeMutableBufferPointer({ mpv_command(mpv, $0.baseAddress) }) >= 0 else { return }

        var paused = false
        while !lock.withLock({ cancelled }) {
            // Hold at the limit rather than racing to the end: unthrottled,
            // the encode ran at 2.2x for the first ten minutes of every
            // episode and after every seek, with the GPU flat out, for
            // frames the TV would not need for minutes.
            let limit = lock.withLock { encodeUntil } ?? .infinity
            if let position = Self.doubleProperty(mpv, "time-pos") {
                lock.withLock { lastPosition = position }
                let hold = position > limit
                if hold != paused {
                    paused = hold
                    var flag: Int32 = hold ? 1 : 0
                    mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                }
            }
            guard let event = mpv_wait_event(mpv, 0.25) else { continue }
            if event.pointee.event_id == MPV_EVENT_END_FILE {
                if let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, end.error < 0 {
                    AppLog.write("[cast] encoder stopped: \(String(cString: mpv_error_string(end.error)))")
                } else {
                    AppLog.write("[cast] encoder reached the end")
                }
                return
            }
            if event.pointee.event_id == MPV_EVENT_SHUTDOWN { return }
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
               let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                AppLog.write("[cast] encoder \(String(cString: message.prefix)): \(String(cString: message.text).trimmingCharacters(in: .newlines))")
            }
        }
    }

    /// The `vf` value: an upscale to fit 3840x2160 with the given chain.
    /// `force_original_aspect_ratio` keeps a scope or 4:3 source from being
    /// stretched to 16:9; the TV letterboxes what is left.
    static func videoFilter(shaderPath: String?) -> String? {
        guard let shaderPath else { return nil }
        return "lavfi=[libplacebo=w=3840:h=2160:force_original_aspect_ratio=decrease:force_divisible_by=2:custom_shader_path=\(shaderPath)]"
    }
}
#endif
