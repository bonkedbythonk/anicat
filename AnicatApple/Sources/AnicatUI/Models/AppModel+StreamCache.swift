import Foundation
import AnicatCoreKit

public extension AppModel {
    /// Bytes the torrent stream cache is holding, or nil before the engine
    /// exists.
    func streamCacheBytes() async -> UInt64? {
        guard let engine else { return nil }
        return await engine.streamCacheBytes()
    }

    /// Drops everything the stream cache holds except what is playing.
    ///
    /// Called when the app leaves the foreground on iOS, and from the button
    /// in Settings. Not called on macOS backgrounding: a Mac keeps running
    /// with its window behind another, and a viewer who alt-tabs away for a
    /// minute has not finished watching.
    func purgeStreamCache() async {
        guard let engine else { return }
        try? await engine.purgeStreamCache()
    }
}
