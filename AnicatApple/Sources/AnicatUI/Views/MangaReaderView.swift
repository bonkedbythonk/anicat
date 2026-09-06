import SwiftUI

public struct MangaReaderView: View {
    public enum ReadingMode: String, CaseIterable, Identifiable {
        case single = "Single Page"
        case double = "Double Page"
        case webtoon = "Vertical Scroll"
        
        public var id: String { rawValue }
        
        public var iconName: String {
            switch self {
            case .single: return "doc"
            case .double: return "book"
            case .webtoon: return "scroll"
            }
        }
    }

    public enum ReadingDirection: String, CaseIterable, Identifiable {
        case rtl = "RTL (Manga)"
        case ltr = "LTR (Webtoon/Comic)"
        
        public var id: String { rawValue }
    }

    public let title: String
    public let chapterTitle: String
    public let pageURLs: [URL]
    public let onPageChanged: (Int) -> Void
    public let onNextChapter: () -> Void
    public let onPrevChapter: () -> Void
    public let onClose: () -> Void

    @State private var currentPageIndex: Int = 0
    @State private var readingMode: ReadingMode = .webtoon
    @State private var readingDirection: ReadingDirection = .rtl
    @State private var showControls: Bool = true
    @State private var currentZoom: CGFloat = 1.0
    @State private var finalZoom: CGFloat = 1.0
    @State private var wasFullScreenBeforeOpen: Bool = false
    @State private var prefetcher = PagePrefetcher()
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    // The statics below are `nonisolated` because `View` is `@MainActor` and
    // a static member inherits that. Swift Testing runs its tests off the main
    // actor, and the executor check the compiler put inside `prefetchIndices`'s
    // filter closure trapped the whole test process (SIGTRAP in
    // `dispatch_assert_queue`) before the first expectation ran. Nothing here
    // touches view state, so the isolation was never needed.

    /// Gap between the two pages of a spread; also subtracted from the width
    /// each page is fitted into.
    nonisolated static let spreadSpacing: CGFloat = 4
    /// The webtoon column's cap, shared with the fit so a page is not decoded
    /// for a width the column never reaches.
    nonisolated static let webtoonMaxWidth: CGFloat = 800

    public init(
        title: String,
        chapterTitle: String,
        pageURLs: [URL],
        initialPage: Int = 0,
        onPageChanged: @escaping (Int) -> Void = { _ in },
        onNextChapter: @escaping () -> Void = {},
        onPrevChapter: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.title = title
        self.chapterTitle = chapterTitle
        self.pageURLs = pageURLs
        self._currentPageIndex = State(initialValue: initialPage)
        self.onPageChanged = onPageChanged
        self.onNextChapter = onNextChapter
        self.onPrevChapter = onPrevChapter
        self.onClose = onClose
    }

    private var pageStep: Int {
        readingMode == .double ? 2 : 1
    }

    private func turnPage(forward: Bool) {
        let delta = forward ? pageStep : -pageStep
        let next = min(max(currentPageIndex + delta, 0), max(pageURLs.count - 1, 0))
        guard next != currentPageIndex else { return }
        currentPageIndex = next
        onPageChanged(next)
    }

    // MARK: - Prefetch window and page fit

    /// The pages to warm around `current`, most useful first: the next turn,
    /// the turn after it, then one turn back. A page turn is a hard cut, so
    /// the next page must be decoded before the key is pressed; the second
    /// page ahead covers a reader who turns faster than one page fetches;
    /// one turn back covers the glance back at the previous page. Reading
    /// direction plays no part: RTL only decides which side of a spread a
    /// page is drawn on, not which page comes next.
    ///
    /// In double mode a turn is two pages and a back turn shows two pages,
    /// so the window is one spread ahead and one spread behind rather than
    /// two spreads ahead: four extra decodes of 2000px+ pages is the most a
    /// reading pace justifies keeping warm.
    ///
    /// In webtoon mode `current` is the page whose row most recently came
    /// into view, which while scrolling down is the last visible one; the
    /// window beyond it is what the scroll is about to reveal.
    nonisolated static func prefetchIndices(current: Int, pageCount: Int, mode: ReadingMode) -> [Int] {
        let shown: Set<Int>
        let candidates: [Int]
        switch mode {
        case .single, .webtoon:
            shown = [current]
            candidates = [current + 1, current + 2, current - 1]
        case .double:
            shown = [current, current + 1]
            candidates = [current + 2, current + 3, current - 2, current - 1]
        }
        return candidates.filter { $0 >= 0 && $0 < pageCount && !shown.contains($0) }
    }

    /// The pixel box a page is fitted into for `mode` in a `container` of
    /// points, at `displayScale` and the settled pinch `zoom`. Sizes are
    /// rounded up to 64px so a live window resize does not re-decode every
    /// page at each intermediate width; rounding up keeps the decode at or
    /// above the displayed size, never below it.
    ///
    /// Zoom is part of the box because `scaleEffect` magnifies whatever was
    /// decoded: a page decoded for the unzoomed frame and then pinched to
    /// 3.5x would be blurrier than the plain `AsyncImage` it replaces. The
    /// cap at native size in the loader means this never decodes more than
    /// the source has.
    nonisolated static func pageFit(mode: ReadingMode, container: CGSize, displayScale: CGFloat, zoom: CGFloat = 1) -> ImageFit {
        let scale = max(displayScale, 1) * max(zoom, 1)
        func px(_ points: CGFloat) -> CGFloat {
            let pixels = max(points, 1) * scale
            return (pixels / 64).rounded(.up) * 64
        }
        switch mode {
        case .single:
            return .box(width: px(container.width), height: px(container.height))
        case .double:
            // A lone final page draws at the full width, but any portrait page
            // is height-limited long before that, so the half width holds.
            return .box(width: px((container.width - spreadSpacing) / 2), height: px(container.height))
        case .webtoon:
            return .box(width: px(min(container.width, webtoonMaxWidth)), height: nil)
        }
    }

    private struct PrefetchPlan: Hashable {
        let urls: [URL]
        let fit: ImageFit
    }

    private func prefetchPlan(fit: ImageFit) -> PrefetchPlan {
        let indices = Self.prefetchIndices(current: currentPageIndex, pageCount: pageURLs.count, mode: readingMode)
        return PrefetchPlan(urls: indices.map { pageURLs[$0] }, fit: fit)
    }

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            // Page Render Content. The GeometryReader is what tells the
            // decoder how large a page is drawn; without it the only size
            // available is a poster-grid guess.
            GeometryReader { geo in
                let fit = Self.pageFit(mode: readingMode, container: geo.size, displayScale: displayScale, zoom: finalZoom)
                Group {
                    switch readingMode {
                    case .webtoon:
                        webtoonView(fit: fit)
                    case .single:
                        singlePageView(fit: fit)
                    case .double:
                        doublePageView(fit: fit)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(currentZoom * finalZoom)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            currentZoom = value
                        }
                        .onEnded { value in
                            finalZoom = min(max(finalZoom * value, 1.0), 3.5)
                            currentZoom = 1.0
                        }
                )
                // Tap zones only apply for paged modes: webtoon already turns pages
                // by scrolling, and a left/right split there would fight the scroll gesture.
                // Middle third toggles controls (matches the old whole-page tap);
                // outer thirds turn pages, mirrored by reading direction.
                .overlay {
                    if readingMode == .webtoon {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.smooth) { showControls.toggle() }
                            }
                    } else {
                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { turnPage(forward: readingDirection == .rtl) }
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.smooth) { showControls.toggle() }
                                }
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { turnPage(forward: readingDirection == .ltr) }
                        }
                    }
                }
                // `initial: true` warms the window for the page the reader
                // opens on; a plan keyed on the fit re-warms after a resize or
                // mode switch, since the cache is keyed on the fit too.
                .onChange(of: prefetchPlan(fit: fit), initial: true) { _, plan in
                    prefetcher.replace(urls: plan.urls, fit: plan.fit)
                }
            }

            // Top Controls Bar
            if showControls {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.leftArrow) {
            turnPage(forward: readingDirection == .rtl)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            turnPage(forward: readingDirection == .ltr)
            return .handled
        }
        .onAppear {
            isFocused = true
            #if os(macOS)
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                wasFullScreenBeforeOpen = window.styleMask.contains(.fullScreen)
                if !wasFullScreenBeforeOpen {
                    window.toggleFullScreen(nil)
                }
            }
            #endif
        }
        .onDisappear {
            prefetcher.cancel()
            #if os(macOS)
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                if window.styleMask.contains(.fullScreen) && !wasFullScreenBeforeOpen {
                    window.toggleFullScreen(nil)
                }
            }
            #endif
        }
    }

    private func exitReader() {
        #if os(macOS)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            if window.styleMask.contains(.fullScreen) && !wasFullScreenBeforeOpen {
                window.toggleFullScreen(nil)
            }
        }
        #endif
        onClose()
    }

    // MARK: - Webtoon (Continuous Vertical) View
    private func webtoonView(fit: ImageFit) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(pageURLs.enumerated()), id: \.offset) { index, url in
                    ReaderPageImage(url: url, fit: fit) {
                        Rectangle()
                            .fill(SumiTheme.card)
                            .frame(height: 600)
                            .overlay(ProgressView())
                    } failure: {
                        Rectangle()
                            .fill(SumiTheme.card)
                            .frame(height: 300)
                            .overlay(
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(SumiTheme.warning)
                            )
                    }
                    .id(index)
                    .onAppear {
                        currentPageIndex = index
                        onPageChanged(index)
                    }
                }
            }
            .frame(maxWidth: Self.webtoonMaxWidth)
        }
    }

    // MARK: - Single Page View
    private func singlePageView(fit: ImageFit) -> some View {
        ZStack {
            if pageURLs.indices.contains(currentPageIndex) {
                ReaderPageImage(url: pageURLs[currentPageIndex], fit: fit) {
                    ProgressView()
                } failure: {
                    ProgressView()
                }
                // Keyed on the URL so a turn builds a fresh view. With one
                // identity across turns, `State(initialValue:)` in the page's
                // init is honored only once, so the prefetched page's
                // synchronous cache hit never reached the first frame, and a
                // turn to a page not yet fetched left the *previous* page on
                // screen with nothing acknowledging the key press.
                .id(pageURLs[currentPageIndex])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Double Page View
    private func doublePageView(fit: ImageFit) -> some View {
        HStack(spacing: Self.spreadSpacing) {
            let leftIndex = readingDirection == .rtl ? currentPageIndex + 1 : currentPageIndex
            let rightIndex = readingDirection == .rtl ? currentPageIndex : currentPageIndex + 1

            // Keyed on the URL for the same reason as the single page view.
            if pageURLs.indices.contains(leftIndex) {
                ReaderPageImage(url: pageURLs[leftIndex], fit: fit) {
                    EmptyView()
                } failure: {
                    EmptyView()
                }
                .id(pageURLs[leftIndex])
            }

            if pageURLs.indices.contains(rightIndex) {
                ReaderPageImage(url: pageURLs[rightIndex], fit: fit) {
                    EmptyView()
                } failure: {
                    EmptyView()
                }
                .id(pageURLs[rightIndex])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            Button(action: exitReader) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .frame(width: 32, height: 32)
                    .background(SumiTheme.card.opacity(0.85))
                    .clipShape(Circle())
            }
            .buttonStyle(.sumiPressable)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Text(chapterTitle)
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }
            .padding(.leading, 8)

            Spacer()

            // Fullscreen Toggle Button
            Button(action: {
                #if os(macOS)
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                #endif
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(SumiTheme.card.opacity(0.85))
                    .clipShape(Circle())
            }
            .buttonStyle(.sumiPressable)
            .padding(.trailing, 4)

            // Reading Direction Toggle
            Button(action: {
                readingDirection = readingDirection == .rtl ? .ltr : .rtl
            }) {
                Text(readingDirection == .rtl ? "RTL" : "LTR")
                    .sumiTabularMono(size: 11, weight: .semibold)
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                    .frame(width: 40, height: 32)
                    .background(SumiTheme.card.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.sumiPressable)
            .animation(.snappy, value: readingDirection)
            .padding(.trailing, 4)

            // Reading Mode Picker
            HStack(spacing: 4) {
                ForEach(ReadingMode.allCases) { mode in
                    Button(action: { readingMode = mode }) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 12))
                            .foregroundColor(readingMode == mode ? SumiTheme.background : SumiTheme.muted)
                            .padding(6)
                            .background(readingMode == mode ? SumiTheme.indigo : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    }
                    .buttonStyle(.sumiPressable)
                    .animation(.snappy, value: readingMode)
                }
            }
            .padding(4)
            .background(SumiTheme.card.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }
        .padding(SumiTheme.spaceMd)
        .background(
            LinearGradient(
                colors: [SumiTheme.background.opacity(0.95), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button(action: onPrevChapter) {
                Text("Prev Chapter")
                    .sumiTabularMono(size: 11, weight: .medium)
                    .foregroundColor(SumiTheme.foreground)
            }
            .buttonStyle(.sumiPressable)

            Spacer()

            Text("Page \(currentPageIndex + 1) / \(max(pageURLs.count, 1))")
                .sumiTabularMono(size: 12, weight: .medium)
                .foregroundColor(SumiTheme.foreground)

            Spacer()

            Button(action: onNextChapter) {
                Text("Next Chapter")
                    .sumiTabularMono(size: 11, weight: .medium)
                    .foregroundColor(SumiTheme.indigo)
            }
            .buttonStyle(.sumiPressable)
        }
        .padding(SumiTheme.spaceMd)
        .background(
            LinearGradient(
                colors: [Color.clear, SumiTheme.background.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Page image

/// A manga page drawn through `ImageDecodeCache`, the same loader as every
/// poster in the app, instead of `AsyncImage`. `AsyncImage` decoded each
/// page at full resolution (1600 to 3000px tall) on every appearance, kept
/// nothing between appearances and shared nothing with a prefetch, so each
/// turn was a cold fetch plus a full decode and the reader stuttered on it.
///
/// Not `CachedAsyncImage` itself because the webtoon column distinguishes a
/// page that failed (a short warning block) from one still loading (a tall
/// spinner block), and that view has only the two-case content/placeholder
/// shape. A failure is not cached, so a page that scrolls away and back is
/// retried, which is what `AsyncImage` did too.
private struct ReaderPageImage<Placeholder: View, Failure: View>: View {
    private enum Phase {
        case loading
        case loaded(CGImage)
        case failed
    }

    let url: URL
    let fit: ImageFit
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var phase: Phase

    init(
        url: URL,
        fit: ImageFit,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.fit = fit
        self.placeholder = placeholder
        self.failure = failure
        // Synchronous cache check at construction, as `CachedAsyncImage`
        // does: a prefetched page must render on the first frame after the
        // turn, and going through `.task` first shows the placeholder for a
        // frame, which reads as the very flicker the prefetch exists to remove.
        // Only reached when the view is built fresh, which is why the paged
        // views key each page on its URL.
        if let cached = ImageDecodeCache.shared.cachedImage(for: url, fit: fit) {
            self._phase = State(initialValue: .loaded(cached))
        } else {
            self._phase = State(initialValue: .loading)
        }
    }

    private struct LoadKey: Hashable {
        let url: URL
        let fit: ImageFit
    }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let cgImage):
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .loading:
                placeholder()
            case .failed:
                failure()
            }
        }
        .task(id: LoadKey(url: url, fit: fit)) {
            if let cached = ImageDecodeCache.shared.cachedImage(for: url, fit: fit) {
                if case .loaded(let current) = phase, current === cached { return }
                phase = .loaded(cached)
                return
            }
            let image = await ImageDecodeCache.shared.image(for: url, fit: fit)
            // The task is cancelled when the row leaves the LazyVStack or the
            // fit changes; writing a stale result would overwrite the newer
            // fit's decode with the old one.
            guard !Task.isCancelled else { return }
            if let image {
                phase = .loaded(image)
            } else if case .loaded = phase {
                // A re-fit that failed keeps the previous decode on screen
                // rather than replacing a readable page with a warning block.
            } else {
                phase = .failed
            }
        }
    }
}

// MARK: - Prefetcher

/// Owns the reader's one outstanding prefetch window. A new window cancels
/// the old task so pages the reader has moved past are never started; the
/// fetches already in flight are shared through the decode cache and finish
/// on their own. `cancel()` on close drops the last window with the reader.
@MainActor
final class PagePrefetcher {
    private var task: Task<Void, Never>?

    func replace(urls: [URL], fit: ImageFit) {
        task?.cancel()
        task = urls.isEmpty ? nil : ImageDecodeCache.shared.prefetch(urls, fit: fit)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
