import Foundation
import UserNotifications
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Local notifications for the two things that happen while the app is not
/// being looked at: an episode of something on the watching list airs, and a
/// download finishes.
///
/// Everything here is lazy on purpose. `UNUserNotificationCenter.current()`
/// raises — it does not return nil, it aborts the process — when the running
/// binary is not inside an `.app`, which is exactly how `swift test` and a
/// bare `swift build` binary run. Touching it from an initializer or a
/// `static let` would take the whole test suite down with it, so every entry
/// point below goes through `isAvailable` first.
public final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = SystemNotifications()

    /// Settings' "New Episode Alerts" switch, written there through
    /// `@AppStorage`. The default matters: an unwritten key reads as `false`
    /// from `UserDefaults.bool(forKey:)`, which would ship the whole feature
    /// off for everyone who never opened Settings.
    public static let newEpisodesKey = "anicat_notify_new_episodes"

    public static var areNewEpisodeNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: newEpisodesKey) != nil else { return true }
        return defaults.bool(forKey: newEpisodesKey)
    }

    /// `<catalogId>:<episode>` pairs already announced, so a refresh that
    /// re-reports the same new episode (every few minutes, for as long as it
    /// stays unwatched) notifies once. In `UserDefaults` rather than memory
    /// because the same episode is still new after a relaunch.
    private static let notifiedEpisodesKey = "anicat_notified_episodes"
    private static let notifiedDownloadsKey = "anicat_notified_downloads"

    /// Trimmed to this many ids when it grows past it. The list only exists
    /// to answer "have I said this already" for episodes still on the
    /// watching list; an unbounded one would carry every episode ever aired
    /// into every launch's defaults read.
    private static let notifiedHistoryLimit = 400

    private let linkKey = "anicat_deep_link"

    /// The binary has to live in an `.app` for the notification centre to
    /// have a bundle to attribute a notification to. `bundleIdentifier` alone
    /// is not the discriminator: a test host has one.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Guards `authorizationState` and the once-only records below. Swift 6
    /// rejects `lock()`/`unlock()` written inside an `async` body outright,
    /// whether or not a suspension point falls between them, so every use is
    /// wrapped in its own synchronous helper — the same shape
    /// `ImageDecodeCache` uses for the decode cache.
    private let stateLock = NSLock()
    private var authorizationState: Bool?

    private override init() {
        super.init()
    }

    /// Installs the delegate. Called from the app's own init rather than
    /// lazily, because `willPresent` has to be in place before the first
    /// notification is delivered, not before the first one is scheduled.
    public func activate() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for permission the first time a notification would actually be
    /// posted, so a viewer who never has a new episode is never prompted.
    private func ensureAuthorized() async -> Bool {
        if let cached = cachedAuthorization() { return cached }
        #if os(tvOS)
        // A TV notification is a badge on the app icon and nothing more:
        // `.alert` and `.sound` are not in the tvOS SDK's option set.
        let options: UNAuthorizationOptions = [.badge]
        #else
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        #endif
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: options)) ?? false
        storeAuthorization(granted)
        return granted
    }

    private func cachedAuthorization() -> Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authorizationState
    }

    private func storeAuthorization(_ granted: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        authorizationState = granted
    }

    // MARK: - Posting

    /// What a release is called, and where its notification goes.
    ///
    /// A chapter is not an episode and cannot be played: tapping one has to
    /// open the title so the reader can be started from it, while an episode
    /// goes straight to playback.
    public enum ReleaseUnit: Sendable {
        case episode
        case chapter

        var noun: String {
            switch self {
            case .episode: return "Episode"
            case .chapter: return "Chapter"
            }
        }
    }

    /// `catalog` for the same reason `notifyDownloadFinished` takes one: the
    /// tap replays a deep link, and a series announced from TMDB whose link
    /// said nothing would have opened -- and played -- whatever anime carries
    /// that number.
    public func notifyNewEpisode(
        catalogId: Int64,
        title: String,
        episode: Int,
        coverURL: URL?,
        unit: ReleaseUnit = .episode,
        catalog: MediaCard.CardCatalog = .anilist
    ) async {
        guard Self.isAvailable, Self.areNewEpisodeNotificationsEnabled else { return }
        // The key carries the unit and the catalog: chapter 5, episode 5 of
        // an anime and episode 5 of the film catalogue's series 5 are three
        // pieces of news, and a shared key would let whichever arrived first
        // silence the rest.
        let key = "\(catalog.rawValue):\(unit == .episode ? "ep" : "ch"):\(catalogId):\(episode)"
        guard markOnce(key: Self.notifiedEpisodesKey, entry: key) else { return }
        await post(
            identifier: "\(unit == .episode ? "episode" : "chapter")-\(catalog.rawValue)-\(catalogId)-\(episode)",
            title: title,
            body: "\(unit.noun) \(episode) is out.",
            coverURL: coverURL,
            link: unit == .episode
                ? .play(id: catalogId, episode: episode, catalog: catalog)
                : .title(id: catalogId, isManga: true, catalog: catalog)
        )
    }

    /// `catalog` is not optional-with-a-default on purpose: the tap replays
    /// this link through `playFromShelf`, whose own catalog defaulted to
    /// AniList, so a finished film announced itself and then played whatever
    /// anime shared its number.
    public func notifyDownloadFinished(
        catalog: MediaCard.CardCatalog,
        catalogId: Int64,
        title: String,
        episode: Int,
        coverURL: URL?
    ) async {
        guard Self.isAvailable else { return }
        let key = "\(catalog.rawValue):\(catalogId):\(episode)"
        guard markOnce(key: Self.notifiedDownloadsKey, entry: key) else { return }
        await post(
            identifier: "download-\(catalog.rawValue)-\(catalogId)-\(episode)",
            title: title,
            body: "Episode \(episode) finished downloading.",
            coverURL: coverURL,
            link: .play(id: catalogId, episode: episode, catalog: catalog)
        )
    }

    private func post(identifier: String, title: String, body: String, coverURL: URL?, link: DeepLink) async {
        #if os(tvOS)
        // `UNMutableNotificationContent` has no title, body, sound or
        // attachments on tvOS; the only thing a notification can do there
        // is badge the icon, which `updateDockBadge` already handles.
        _ = (identifier, title, body, coverURL, link)
        return
        #else
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [linkKey: link.url.absoluteString]
        if let coverURL, let attachment = await Self.coverAttachment(for: coverURL, identifier: identifier) {
            content.attachments = [attachment]
        }

        // A nil trigger delivers immediately. The alternative — a
        // `UNTimeIntervalNotificationTrigger` with a tiny interval — is
        // rejected below one second, so there is nothing to gain from it.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }

    #if !os(tvOS)
    /// `UNNotificationAttachment` takes a file, not bytes, and the system
    /// *moves* the file into its own store — so this writes a fresh temp copy
    /// per notification rather than pointing at anything the image cache owns.
    private static func coverAttachment(for url: URL, identifier: String) async -> UNNotificationAttachment? {
        guard let image = ImageDecodeCache.shared.cachedImage(for: url, maxPixelSize: 256) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anicat-\(identifier)-\(UUID().uuidString).png")
        guard (try? (data as Data).write(to: fileURL)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: identifier, url: fileURL, options: nil)
    }
    #endif

    // MARK: - Once-only bookkeeping

    /// Records `entry` and answers whether it was new. Read-modify-write on
    /// `UserDefaults` under the lock, because the episode check and the
    /// download check each announce from their own detached task and an
    /// unguarded pair of them loses one list to the other's write.
    private func markOnce(key: String, entry: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !seen.contains(entry) else { return false }
        seen.append(entry)
        if seen.count > Self.notifiedHistoryLimit {
            seen.removeFirst(seen.count - Self.notifiedHistoryLimit)
        }
        UserDefaults.standard.set(seen, forKey: key)
        return true
    }

    // MARK: - Delegate

    /// Without this, a notification that arrives while Anicat is the frontmost
    /// app is dropped silently — which is the common case here, since the
    /// refresh that discovers a new episode runs in the app the viewer is
    /// looking at.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if os(tvOS)
        completionHandler([.badge])
        #else
        completionHandler([.banner, .sound])
        #endif
    }

    // A tvOS notification cannot be tapped -- there is nothing to tap and no
    // `UNNotificationResponse` in the SDK -- so the routing half of the
    // delegate does not exist there.
    #if !os(tvOS)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[linkKey] as? String
        let link = raw.flatMap(URL.init(string:)).flatMap(DeepLink.init(url:))
        if let link {
            Task { @MainActor in
                AppModel.shared?.handleDeepLink(link)
            }
        }
        // Called before the routing task rather than inside it: the handler
        // is not `Sendable`, so carrying it into a `@MainActor` task is a
        // data race the compiler rejects — and it only tells the system the
        // response has been taken, not that the app has finished acting on it.
        completionHandler()
    }
    #endif
}
