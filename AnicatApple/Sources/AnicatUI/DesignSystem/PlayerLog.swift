import Foundation

/// A plain append-only log at ~/Library/Logs/Anicat/player.log.
///
/// NSLog lines from the player never showed up in `log show` on the
/// owner's machine, twice, so diagnosis stalled on an empty paste. A file
/// the owner can `cat` does not depend on the unified log's mood. Kept
/// small: it is truncated when it passes 512 KB, and only the size and
/// sampler lines go here.
enum PlayerLog {
    private static let queue = DispatchQueue(label: "app.anicat.playerlog", qos: .utility)
    private static let url: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = library.appendingPathComponent("Logs/Anicat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("player.log")
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        NSLog("%@", line)
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 512 * 1024 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(text.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
