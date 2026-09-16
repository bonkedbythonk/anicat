import Foundation
import Libmpv

/// Decodes a stretch of an episode's audio to raw mono PCM for opening and
/// ending detection (`core/src/skip.rs`), with a second, headless libmpv.
///
/// mpv rather than anything of Apple's: AVFoundation does not open MKV, and
/// this is the decoder the player already trusts with every release. With
/// `untimed` and `ao=pcm` it decodes as fast as the data arrives: eight
/// minutes of a complete 1080p remux came out in 1.4 s. It reads the same
/// loopback URL the player does, so on a torrent it pulls the pieces it needs
/// through the range server rather than reading holes in a sparse file (mpv
/// refused a 14 MB-of-5.9 GB file outright: "Failed to recognize file
/// format").
enum AudioExtractor {
    /// Must match `skip::SAMPLE_RATE`.
    static let sampleRate = 11_025

    /// Writes `length` seconds from `start` to `output`. Answers whether a
    /// useful amount of audio came out: a stream that stalls is abandoned at
    /// `timeout` and whatever it wrote is not trusted.
    static func extract(
        url: String,
        start: Double,
        length: Double,
        preferDub: Bool,
        to output: URL,
        timeout: TimeInterval = 180
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            run(url: url, start: start, length: length, preferDub: preferDub, output: output, timeout: timeout)
        }.value
    }

    private static func run(url: String, start: Double, length: Double, preferDub: Bool, output: URL, timeout: TimeInterval) -> Bool {
        try? FileManager.default.removeItem(at: output)
        guard let mpv = mpv_create() else { return false }
        defer { mpv_terminate_destroy(mpv) }
        let options: [(String, String)] = [
            ("config", "no"),
            ("terminal", "no"),
            ("load-scripts", "no"),
            ("input-default-bindings", "no"),
            ("vid", "no"),
            ("sid", "no"),
            ("hwdec", "no"),
            // The same language the player picks, or the two episodes of a
            // pair can decode different tracks. A dual-audio remux's Japanese
            // stereo and its 5.1 downmix shared 30 s of a 119 s stretch.
            ("alang", preferDub ? "eng,en" : "jpn,ja"),
            ("ao", "pcm"),
            ("ao-pcm-file", output.path),
            ("ao-pcm-waveheader", "no"),
            ("audio-format", "s16"),
            ("audio-channels", "mono"),
            ("audio-samplerate", String(sampleRate)),
            ("untimed", "yes"),
            ("start", String(format: "%.2f", max(start, 0))),
            ("length", String(format: "%.2f", length)),
        ]
        for (name, value) in options {
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else { return false }
        var args: [UnsafePointer<CChar>?] = ["loadfile", url].map { (arg: String) -> UnsafePointer<CChar>? in
            UnsafePointer(strdup(arg))
        }
        args.append(nil)
        defer { args.forEach { $0.map { free(UnsafeMutableRawPointer(mutating: $0)) } } }
        let sent = args.withUnsafeMutableBufferPointer { mpv_command(mpv, $0.baseAddress) }
        guard sent >= 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            guard let event = mpv_wait_event(mpv, 0.5) else { continue }
            if event.pointee.event_id == MPV_EVENT_END_FILE || event.pointee.event_id == MPV_EVENT_SHUTDOWN {
                finished = true
                break
            }
        }
        guard finished else {
            print("[skipdetect] audio extraction timed out after \(Int(timeout))s")
            return false
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        // Two bytes a sample. Under half the asked-for length is a stream
        // that ended early or never opened; fingerprinting it would compare
        // a fragment and call the result an opening.
        return bytes >= Int(length * 0.5) * sampleRate * 2
    }
}
