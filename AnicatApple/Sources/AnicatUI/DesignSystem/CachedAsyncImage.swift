import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// How an image is bounded when it is decoded. `ImageIO`'s thumbnail API
/// only knows one number, the cap on the *largest* side, and for poster art
/// that is the whole story. It is the wrong shape for a manga page fitted
/// into a box: a webtoon strip of 800x6000 bounded by its largest side at a
/// 1600px-wide column comes out 213px wide, drawn at 1600, unreadable. `box`
/// reads the source's pixel size from its header first and turns the box
/// into the largest-side cap that makes the *fitted* image exactly the
/// displayed size.
public enum ImageFit: Hashable, Sendable {
    /// Cap on the largest side, in pixels. Poster grids and thumbnails.
    case maxPixelSize(CGFloat)
    /// Aspect-fit into `width` x `height` pixels. A nil height means only
    /// the width constrains, which is a vertical scroll.
    case box(width: CGFloat, height: CGFloat?)

    /// Part of the decode-cache key. `Int(CGFloat.infinity)` traps, which is
    /// why the unconstrained axis is spelled as nil and not as infinity.
    var cacheKeySuffix: String {
        switch self {
        case .maxPixelSize(let px):
            return "#\(Int(px))"
        case .box(let width, let height):
            return "#box:\(Int(width))x\(height.map { String(Int($0)) } ?? "any")"
        }
    }
}

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
        // An absolute directory, not the bare name this used to pass. A
        // relative `diskPath` is resolved against the process's working
        // directory, which is `/` for anything launched from Finder or
        // `open` — so every normal launch logged "NetworkStorageDB: failed
        // to open read/write connection to DB @ anicat_image_cache/Cache.db"
        // and ran with the memory cache alone. Cover art was refetched from
        // AniList's CDN on every cold start while the 200 MB disk budget
        // above was never once used.
        config.urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            directory: imageCacheDirectory()
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// `nil` when the directory cannot be created, which leaves `URLCache`
    /// on its own default location rather than on a path it cannot write.
    private static func imageCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("Anicat/images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory
    }

    private init() {
        cache.countLimit = 500
        // The count limit was sized for posters, which decode to about 1 MB
        // each. Manga pages go through this cache too, and one page decoded
        // for a 1600px webtoon column at 3000px tall is ~19 MB, so the count
        // limit alone let an 80-page chapter keep ~1.5 GB resident after the
        // reader had closed. Posters are far under this and stay governed by
        // the count.
        cache.totalCostLimit = 512 * 1024 * 1024
    }

    func cachedImage(for url: URL, maxPixelSize: CGFloat) -> CGImage? {
        cachedImage(for: url, fit: .maxPixelSize(maxPixelSize))
    }

    func cachedImage(for url: URL, fit: ImageFit) -> CGImage? {
        let key = (url.absoluteString + fit.cacheKeySuffix) as NSString
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
        // Without a cost `totalCostLimit` counts every entry as zero and
        // never evicts on size.
        cache.setObject(Box(image), forKey: nsKey, cost: image.bytesPerRow * image.height)
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
        await image(for: url, fit: .maxPixelSize(maxPixelSize))
    }

    /// `priority` is the priority of the fetch-and-decode task when this call
    /// is the one that starts it. A later caller that joins the same in-flight
    /// task escalates it by awaiting, so a page the reader prefetched at
    /// `.utility` and then turned to is decoded at the visible caller's
    /// priority, not left behind the queue it was started in.
    func image(for url: URL, fit: ImageFit, priority: TaskPriority = .userInitiated) async -> CGImage? {
        let key = url.absoluteString + fit.cacheKeySuffix
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
        let task = Task.detached(priority: priority) { () -> CGImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data: data, fit: fit)
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
    nonisolated private static func downsample(data: Data, fit: ImageFit) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let maxPixelSize: CGFloat
        switch fit {
        case .maxPixelSize(let px):
            maxPixelSize = px
        case .box(let width, let height):
            guard let sourceSize = pixelSize(of: source) else {
                // Without the source's dimensions the box cannot be turned
                // into a largest-side cap that is safe for every aspect ratio,
                // so decode at native size: more memory for one page beats a
                // tall strip squashed to the column width.
                return CGImageSourceCreateImageAtIndex(source, 0, sourceOptions)
            }
            maxPixelSize = thumbnailMaxPixelSize(source: sourceSize, boxWidth: width, boxHeight: height)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Reads the pixel size from the container header, which does not decode
    /// the image. EXIF orientations 5-8 are drawn rotated a quarter turn, and
    /// `kCGImageSourceCreateThumbnailWithTransform` applies that rotation, so
    /// the size the box is fitted against has to be the rotated one.
    nonisolated private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let rotated = (5...8).contains(orientation)
        return rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The largest-side cap that makes `source`, aspect-fitted into the box,
    /// come out at the displayed size. Never asks for more than the source
    /// has: ImageIO would not upscale anyway, but a cap above the native
    /// size makes the cache key promise a resolution the image cannot have.
    nonisolated static func thumbnailMaxPixelSize(source: CGSize, boxWidth: CGFloat, boxHeight: CGFloat?) -> CGFloat {
        var scale = boxWidth / source.width
        if let boxHeight {
            scale = min(scale, boxHeight / source.height)
        }
        scale = min(scale, 1)
        return ceil(max(source.width, source.height) * scale)
    }

    /// Warms the cache for images that are about to be displayed, in the
    /// order given. The manga reader needs this because a page turn is a
    /// hard cut with no scroll to hide the load behind: the next page has to
    /// be fetched and decoded before the key is pressed, and
    /// `CachedAsyncImage` only starts loading once the page is on screen.
    ///
    /// One task, sequential, rather than one task per URL: three concurrent
    /// page fetches share the connection with the page the reader is
    /// actually waiting on, and the most likely page (first in the list) is
    /// the one that should have the bandwidth. Cancelling the returned task
    /// stops the URLs not yet started; a fetch already in flight is shared
    /// with anyone who asks for the same image, so it runs to completion and
    /// lands in the cache, which is why a stale prefetch is harmless rather
    /// than wasted.
    @discardableResult
    func prefetch(_ urls: [URL], fit: ImageFit) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            for url in urls {
                guard !Task.isCancelled else { return }
                if cachedImage(for: url, fit: fit) != nil { continue }
                _ = await image(for: url, fit: fit, priority: .utility)
            }
        }
    }
}

/// Drop-in replacement for the two-case (`content`/`placeholder`) form of
/// `AsyncImage`, backed by `ImageDecodeCache`. `maxPixelSize` should be the
/// image's largest on-screen dimension in *pixels* (points × the display's
/// backing scale) — passing a display-scale-aware size is what makes the
/// downsample actually smaller than the source instead of a no-op.
public struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let fit: ImageFit
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var cgImage: CGImage?

    public init(
        url: URL?,
        maxPixelSize: CGFloat = 480,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(url: url, fit: .maxPixelSize(maxPixelSize), content: content, placeholder: placeholder)
    }

    /// `fit: .box` is for an image fitted into a known frame, where the
    /// largest-side cap would be wrong for tall sources (see `ImageFit`).
    public init(
        url: URL?,
        fit: ImageFit,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fit = fit
        self.content = content
        self.placeholder = placeholder

        if let url, let cached = ImageDecodeCache.shared.cachedImage(for: url, fit: fit) {
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
        // Keyed on the fit too: the reader re-fits its pages when the window
        // is resized, and a task keyed on the URL alone would never re-run,
        // leaving the old decode on screen at the new size.
        .task(id: LoadKey(url: url, fit: fit)) {
            guard let url else {
                cgImage = nil
                return
            }
            if let cached = ImageDecodeCache.shared.cachedImage(for: url, fit: fit) {
                if cgImage !== cached {
                    cgImage = cached
                }
                return
            }
            cgImage = await ImageDecodeCache.shared.image(for: url, fit: fit)
        }
    }

    private struct LoadKey: Hashable {
        let url: URL?
        let fit: ImageFit
    }
}
