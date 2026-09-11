import Foundation

/// The app's log file: `~/Library/Logs/Anicat/anicat.log`, one per launch,
/// the three before it kept as `.1` to `.3`.
///
/// Everything the process says goes there. The Rust engine's `env_logger`
/// writes to stderr, mpv's own messages go to stderr, and every `print`
/// goes to stdout -- and a bundle opened from the Dock has both attached
/// to nothing, so every `[resolve]` timing and every mpv error a user
/// could have attached to a bug report was dropped on the floor. `start`
/// points file descriptors 1 and 2 at the log file with `dup2`, which
/// catches all three writers at once without any of them knowing. Run
/// from a terminal (the descriptors are a TTY) the output stays on the
/// terminal, and only this type's own lines are copied into the file.
///
/// Why not `os.Logger`: `log show` on the owner's machine twice returned
/// nothing for the player's NSLog lines, and a file the user can open in
/// Finder does not depend on the unified log's mood or on knowing a
/// predicate. Why not a log crate on the Rust side writing its own file:
/// it would miss mpv and Swift, and two files is two things to attach.
public enum AppLog {
    public static let directoryURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return library.appendingPathComponent("Logs/Anicat", isDirectory: true)
    }()
    public static let fileURL = directoryURL.appendingPathComponent("anicat.log")

    /// How many earlier launches are kept beside the current one. Three is
    /// enough to hold the launch a bug happened in through the relaunch
    /// that goes looking for it.
    static let keptLaunches = 3

    private static let queue = DispatchQueue(label: "app.anicat.log", qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        // UTC and ISO, the same shape `env_logger` stamps its lines with,
        // so the two kinds of line sort together in one file.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
    // Written once in `start`, before any scene exists, and read-only after.
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    /// True when stdout and stderr were pointed at the file, so a `print`
    /// or a Rust log line is already in it and `write` must not copy.
    nonisolated(unsafe) public private(set) static var capturesProcessOutput = false

    /// Call first thing in the app's `init`, before the engine is built:
    /// `env_logger` is installed by `AnicatEngine::new` and resolves stderr
    /// per write, so redirecting before that is enough, but nothing said
    /// earlier can be recovered.
    public static func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        rotate()

        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        if isatty(STDERR_FILENO) == 0 {
            dup2(fd, STDOUT_FILENO)
            dup2(fd, STDERR_FILENO)
            close(fd)
            // stdout is fully buffered when it is not a terminal, so a
            // `print` would sit in the buffer until 4 KB had accumulated
            // and the crash it was describing would never reach the file.
            setvbuf(stdout, nil, _IOLBF, 0)
            capturesProcessOutput = true
        } else {
            fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        write("Anicat \(version) (\(build)) on \(Platform.osName) \(os), \(hardwareModel), log at \(fileURL.path)")
    }

    /// One line, timestamped. Goes to stderr (the terminal, or the file
    /// once redirected) and, when stderr is a terminal, into the file as
    /// well so the file is complete either way.
    public static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let data = Data(text.utf8)
            FileHandle.standardError.write(data)
            if !capturesProcessOutput, let fileHandle {
                fileHandle.write(data)
            }
        }
    }

    /// `anicat.log` becomes `.1`, `.1` becomes `.2`, and so on; the oldest
    /// is dropped. The pre-6.0.1 `player.log` is removed on the way, since
    /// its lines now land here.
    private static func rotate() {
        let fm = FileManager.default
        let oldest = directoryURL.appendingPathComponent("anicat.log.\(keptLaunches)")
        try? fm.removeItem(at: oldest)
        for index in stride(from: keptLaunches - 1, through: 1, by: -1) {
            let from = directoryURL.appendingPathComponent("anicat.log.\(index)")
            let to = directoryURL.appendingPathComponent("anicat.log.\(index + 1)")
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
        }
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.moveItem(at: fileURL, to: directoryURL.appendingPathComponent("anicat.log.1"))
        }
        try? fm.removeItem(at: directoryURL.appendingPathComponent("player.log"))
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown hardware" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
