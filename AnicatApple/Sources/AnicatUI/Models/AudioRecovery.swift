import Foundation

/// How many times the app looks for another release on its own when a file
/// opens without the language the viewer asked for.
///
/// Each look names a release that failed, so the walk through a title's
/// candidates always ends; the cap is for the case where a show has more
/// releases than anyone wants to wait through, and for a bug in the pieces
/// around this one. A viewer pressing Sub or Dub starts the count over, since
/// that is a new request, and a file that does carry the language ends it.
struct AudioRecovery {
    static let maxAttempts = 4

    struct Key: Hashable {
        let catalogId: Int64
        let episode: Int64
        let preferDub: Bool
    }

    private var attempts: [Key: Int] = [:]

    /// Whether another attempt may start. Counts it when it may.
    mutating func begin(_ key: Key, userInitiated: Bool) -> Bool {
        if userInitiated { attempts[key] = 0 }
        let used = attempts[key, default: 0]
        guard used < Self.maxAttempts else { return false }
        attempts[key] = used + 1
        return true
    }

    /// Attempts started for `key`: above one means a search already swapped
    /// the file at least once.
    func count(_ key: Key) -> Int {
        attempts[key, default: 0]
    }

    /// The file has the language: nothing to recover from, count cleared.
    mutating func settle(_ key: Key) {
        attempts[key] = nil
    }
}
