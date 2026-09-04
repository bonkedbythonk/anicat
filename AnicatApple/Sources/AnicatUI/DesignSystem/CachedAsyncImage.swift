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
@MainActor
final class ImageDecodeCache {
    static let shared = ImageDecodeCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixelSize))" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.image
        }
        if let existing = inFlight[key as String] {
            return await existing.value
        }

        let task = Task<CGImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }
        inFlight[key as String] = task
        let result = await task.value
        inFlight[key as String] = nil
        if let result {
            cache.setObject(Box(result), forKey: key)
        }
        return result
    }

    /// Runs on the calling task's executor, not the main actor — `ImageIO`'s
    /// thumbnail decode is the actual CPU cost being avoided on scroll, so it
    /// still has to happen off it.
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
    }

    public var body: some View {
        Group {
            if let cgImage {
                content(Image(decorative: cgImage, scale: 1))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                cgImage = nil
                return
            }
            // A cache hit resolves synchronously inside the `Task`, so this
            // never shows the placeholder for an image that's already
            // decoded — only a genuine first fetch does.
            cgImage = await ImageDecodeCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}
