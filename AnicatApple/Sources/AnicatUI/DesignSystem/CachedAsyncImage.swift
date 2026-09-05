import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Decodes and caches images at the pixel size they're actually displayed
/// at, instead of `AsyncImage`'s full-resolution decode on every appearance.
/// AniList cover art commonly ships at 400-600pt wide; a poster grid cell
/// draws it at ~165-200pt (330-400px at retina). Every scroll that brings a
/// card back on screen re-decodes and re-composites that full-size image
/// with plain `AsyncImage`, which is the concrete reason a card grid feels
/// like it's dropping frames well before it's anywhere near the item count
/// that would actually justify it — the decode is the same cost every time,
/// scroll or not, but a 120Hz frame budget is half a 60Hz one and has no
/// slack left for it.
///
/// Thread-safety: deliberately NOT `@MainActor`. Cache reads and writes are
/// guarded by `cacheLock`. This means decode completions never need to hop
/// back to the main actor just to write to the cache — they write directly
/// from the background task, then publish the result to SwiftUI (which does
/// its own main-actor marshalling). Eliminating these unnecessary main-actor
/// hops reduces the "30 main thread stalls" the FPS HUD reports.
final class ImageDecodeCache: @unchecked Sendable {
    static let shared = ImageDecodeCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let cacheLock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let memoryCapacity = 50 * 1024 * 1024 // 50 MB
        let diskCapacity = 200 * 1024 * 1024 // 200 MB
        config.urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: "anicat_image_cache"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private init() {
        cache.countLimit = 500
    }

    func cachedImage(for url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixelSize))" as NSString
        return lockedCache(nsKey: key)
    }

    // Swift 6 flags `NSLock.lock()/unlock()` written directly inside an
    // `async` function body as unavailable, regardless of whether a
    // suspension point actually falls between them. Isolating each
    // lock/unlock pair in its own synchronous, nonisolated function sidesteps
    // that check without changing the locking behavior.
    private nonisolated func lockedCache(nsKey: NSString) -> CGImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.object(forKey: nsKey)?.image
    }

    private nonisolated func storeCache(nsKey: NSString, image: CGImage) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.setObject(Box(image), forKey: nsKey)
    }

    private nonisolated func takeInFlight(key: String) -> Task<CGImage?, Never>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[key]
    }

    private nonisolated func setInFlight(key: String, task: Task<CGImage?, Never>) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[key] = task
    }

    private nonisolated func clearInFlight(key: String) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[key] = nil
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixelSize))"
        let nsKey = key as NSString

        if let hit = lockedCache(nsKey: nsKey) {
            return hit
        }

        if let existing = takeInFlight(key: key) {
            return await existing.value
        }

        let session = Self.session
        // Runs on a background cooperative worker thread rather than inheriting @MainActor:
        // CGImageSource thumbnail decoding is CPU-heavy and must never block the 120Hz display link.
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }
        setInFlight(key: key, task: task)

        let result = await task.value

        clearInFlight(key: key)

        if let result {
            storeCache(nsKey: nsKey, image: result)
        }
        return result
    }

    /// Runs off the main actor — `ImageIO`'s thumbnail decode is the actual CPU
    /// cost being avoided on scroll.
    nonisolated private static func downsample(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}

/// Drop-in replacement for the two-case (`content`/`placeholder`) form of
/// `AsyncImage`, backed by `ImageDecodeCache`. `maxPixelSize` should be the
/// image's largest on-screen dimension in *pixels* (points × the display's
/// backing scale) — passing a display-scale-aware size is what makes the
/// downsample actually smaller than the source instead of a no-op.
public struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let maxPixelSize: CGFloat
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var cgImage: CGImage?

    public init(
        url: URL?,
        maxPixelSize: CGFloat = 480,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = content
        self.placeholder = placeholder

        if let url, let cached = ImageDecodeCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            self._cgImage = State(initialValue: cached)
        } else {
            self._cgImage = State(initialValue: nil)
        }
    }

    public var body: some View {
        Group {
            if let cgImage {
                content(Image(decorative: cgImage, scale: 1))
                    .transition(.opacity)
            } else {
                placeholder()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else {
                cgImage = nil
                return
            }
            if let cached = ImageDecodeCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
                if cgImage !== cached {
                    cgImage = cached
                }
                return
            }
            cgImage = await ImageDecodeCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}
