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

        /// Positive x is to the right on screen. A right-to-left book advances
        /// leftwards, so the page arriving during a forward turn comes in from
        /// the left and the one leaving exits to the right.
        var forwardSlideSign: CGFloat { self == .rtl ? -1 : 1 }
    }

    /// How a reading mode takes pointer and keyboard input. Pointer and
    /// keyboard are one decision, not two: a mode that turns a page on an
    /// arrow key is the same mode that splits the frame into tap zones, and
    /// a mode that scrolls has to let both the scroll wheel and the arrow
    /// keys reach the scroll view.
    public enum InputMode {
        /// Outer thirds turn the page, the middle third toggles the
        /// controls, and left/right arrows turn the page.
        case pageTurn
        /// The scroll view owns the gesture: nothing is laid over it, the
        /// tap to toggle the controls rides on the page rows inside the
        /// scroll content, and arrow keys are passed on untouched.
        case scroll
    }

    public let title: String
    public let chapterTitle: String
    public let pageURLs: [URL]
    public let onPageChanged: (Int) -> Void
    public let onNextChapter: () -> Void
    public let onPrevChapter: () -> Void
    public let onClose: () -> Void

    /// In `.double` this is the *first* page of the open spread, not an
    /// arbitrary page inside it, so `onPageChanged` keeps meaning the same
    /// thing to the Handoff advertisement in every mode.
    @State private var currentPageIndex: Int = 0
    @State private var readingMode: ReadingMode
    @State private var readingDirection: ReadingDirection
    @State private var offsetCover: Bool
    @State private var showControls: Bool = true
    @State private var currentZoom: CGFloat = 1.0
    @State private var finalZoom: CGFloat = 1.0
    @State private var wasFullScreenBeforeOpen: Bool = false
    @State private var prefetcher = PagePrefetcher()
    /// Which pages turned out to be wide enough to be a double-page spread of
    /// their own. Learned from the decoded pixels rather than declared: a page
    /// list is URLs, and nothing in it says how a page is shaped.
    @State private var wideIndices: Set<Int> = []
    @State private var lastTurnWasForward = true
    @State private var didPreloadNextChapter = false
    @State private var didFinishChapter = false
    @State private var syncToast = false
    @State private var swipeMonitor = TrackpadSwipeMonitor()
    /// The catalog id the per-title preferences are keyed on, read once at
    /// construction. `nil` for a title with no AniList entry behind it, which
    /// `ReaderPreferences` folds onto the global keys.
    private let catalogId: Int64?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Above this width-over-height ratio a page is a printed double spread
    /// already and must stand alone; pairing it with a neighbour would draw
    /// two half-width pages where one full-width one belongs. 1.2 rather than
    /// 1.0 because a portrait page scanned with its facing gutter runs a
    /// little past square without being a spread.
    nonisolated static let spreadAspectThreshold: CGFloat = 1.2
    /// How far a page slides while it crossfades. Small on purpose: the turn
    /// reads as a cut with a direction, not as a carousel.
    nonisolated static let pageSlide: CGFloat = 6

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
        // `AppModel.openReader` points the bridge at the session on this same
        // actor immediately before assigning `activeReadingSession`, which is
        // what causes this view to be built, so the id is already there and
        // the preferences below are the title's own from the first frame.
        let catalogId = ReaderBridge.shared.catalogId
        self.catalogId = catalogId
        self._readingMode = State(initialValue: ReaderPreferences.mode(catalogId: catalogId))
        self._readingDirection = State(
            initialValue: ReaderPreferences.isRightToLeft(catalogId: catalogId) ? .rtl : .ltr
        )
        self._offsetCover = State(initialValue: ReaderPreferences.offsetsCover(catalogId: catalogId))
    }

    // MARK: - Spread pairing

    /// Pairs pages into what is drawn at once.
    ///
    /// Every mode but `.double` is one page at a time, so this only has to
    /// answer for spreads: a wide page is a printed spread already and stands
    /// alone, and `offsetCover` puts the first page alone so every pair after
    /// it lands on the pairing the book was printed with — a cover is a single
    /// leaf, and without the offset every spread in the volume is off by one.
    ///
    /// `wideIndices` is what the reader has decoded so far, so a page can turn
    /// out wide after its spread was already laid out and the spreads after it
    /// shift by one. That reflow is the cost of not knowing a page's shape
    /// before fetching it: a page list is URLs. The prefetch window answers
    /// for the pages ahead, so a turn lands on a spread already known to be
    /// one — but the *opening* spread of a chapter is drawn before anything in
    /// it has been decoded, so a wide cover re-pairs itself a frame later.
    /// "Offset cover" is the setting that avoids that on a title where it
    /// happens every chapter.
    nonisolated static func spreads(pageCount: Int, wideIndices: Set<Int>, offsetCover: Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        var result: [[Int]] = []
        var index = 0
        if offsetCover {
            result.append([0])
            index = 1
        }
        while index < pageCount {
            if wideIndices.contains(index) {
                result.append([index])
                index += 1
            } else if index + 1 < pageCount, !wideIndices.contains(index + 1) {
                result.append([index, index + 1])
                index += 2
            } else {
                // Either the last page of an odd chapter, or the page before a
                // wide one: both stand alone rather than being paired with
                // something that cannot share the frame.
                result.append([index])
                index += 1
            }
        }
        return result
    }

    /// Which spread `page` falls in. A page can briefly be outside every
    /// spread while a chapter is being replaced, so the clamp is the answer
    /// rather than a crash.
    nonisolated static func spreadIndex(containing page: Int, spreads: [[Int]]) -> Int {
        guard !spreads.isEmpty else { return 0 }
        return spreads.firstIndex(where: { $0.contains(page) }) ?? min(max(page, 0), spreads.count - 1)
    }

    private var currentSpreads: [[Int]] {
        Self.spreads(pageCount: pageURLs.count, wideIndices: wideIndices, offsetCover: offsetCover)
    }

    /// The pages drawn right now, in page order. Reading direction is applied
    /// where they are laid out, not here, so the prefetch and the progress
    /// readout never have to think about it.
    private var visiblePages: [Int] {
        switch readingMode {
        case .single, .webtoon:
            return pageURLs.indices.contains(currentPageIndex) ? [currentPageIndex] : []
        case .double:
            let spreads = currentSpreads
            guard !spreads.isEmpty else { return [] }
            return spreads[Self.spreadIndex(containing: currentPageIndex, spreads: spreads)]
        }
    }

    private func turnPage(forward: Bool) {
        let next: Int
        switch readingMode {
        case .single, .webtoon:
            next = min(max(currentPageIndex + (forward ? 1 : -1), 0), max(pageURLs.count - 1, 0))
        case .double:
            let spreads = currentSpreads
            guard !spreads.isEmpty else { return }
            let current = Self.spreadIndex(containing: currentPageIndex, spreads: spreads)
            let target = min(max(current + (forward ? 1 : -1), 0), spreads.count - 1)
            next = spreads[target][0]
        }
        guard next != currentPageIndex else {
            // Already on the last spread, so this turn is what finishes the
            // chapter; a reader who never turns again would otherwise never
            // reach the sync below.
            if forward { noteReadingPosition(currentPageIndex) }
            return
        }
        lastTurnWasForward = forward
        withAnimation(pageAnimation) { currentPageIndex = next }
        onPageChanged(next)
        noteReadingPosition(next)
    }

    // MARK: - Chapter preload and AniList sync

    /// How far through the chapter the reader has got, as the fraction of
    /// pages behind them once what is on screen has been read.
    ///
    /// Derived from `page` rather than from `visiblePages`, which reads
    /// `currentPageIndex`: this is called from `turnPage` immediately after
    /// that state is written, and a fraction computed against the page the
    /// reader has just left is one spread short of the truth.
    private func readFraction(at page: Int) -> Double {
        guard pageURLs.count > 0 else { return 0 }
        let lastShown: Int
        switch readingMode {
        case .single, .webtoon:
            lastShown = page
        case .double:
            let spreads = currentSpreads
            let index = Self.spreadIndex(containing: page, spreads: spreads)
            lastShown = spreads.indices.contains(index) ? (spreads[index].last ?? page) : page
        }
        return Double(max(page, lastShown) + 1) / Double(pageURLs.count)
    }

    private func noteReadingPosition(_ page: Int) {
        let fraction = readFraction(at: page)
        if !didPreloadNextChapter, fraction >= ReaderBridge.preloadThreshold {
            didPreloadNextChapter = true
            ReaderBridge.shared.preloadNextChapter()
        }
        guard !didFinishChapter, fraction >= 1.0 else { return }
        didFinishChapter = true
        Task {
            guard await ReaderBridge.shared.finishChapter() else { return }
            withAnimation(.snappy) { syncToast = true }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.snappy) { syncToast = false }
        }
    }

    // MARK: - Motion

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .snappy
    }

    /// Crossfade with a short slide in the direction of travel. Under Reduce
    /// Motion the slide is dropped and the crossfade stays: a page turn with
    /// no visual acknowledgement at all reads as a dropped key press.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let sign = readingDirection.forwardSlideSign * (lastTurnWasForward ? 1 : -1)
        return .asymmetric(
            insertion: .offset(x: Self.pageSlide * sign).combined(with: .opacity),
            removal: .offset(x: -Self.pageSlide * sign).combined(with: .opacity)
        )
    }

    private func notePageSize(index: Int, size: CGSize) {
        guard size.height > 0 else { return }
        let isWide = size.width / size.height > Self.spreadAspectThreshold
        if isWide, !wideIndices.contains(index) {
            withAnimation(pageAnimation) { _ = wideIndices.insert(index) }
        } else if !isWide, wideIndices.contains(index) {
            withAnimation(pageAnimation) { _ = wideIndices.remove(index) }
        }
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
    /// Webtoon scrolls, every other mode turns pages. `nonisolated` for the
    /// same reason as the members below it.
    nonisolated static func inputMode(for mode: ReadingMode) -> InputMode {
        mode == .webtoon ? .scroll : .pageTurn
    }

    nonisolated static func prefetchIndices(
        current: Int,
        pageCount: Int,
        mode: ReadingMode,
        wideIndices: Set<Int> = [],
        offsetCover: Bool = false
    ) -> [Int] {
        let shown: Set<Int>
        let candidates: [Int]
        switch mode {
        case .single, .webtoon:
            shown = [current]
            candidates = [current + 1, current + 2, current - 1]
        case .double:
            // Read off the spread list rather than assumed to be pairs at even
            // offsets: with a wide page or an offset cover in the chapter, a
            // fixed `current + 2` warms a page from the middle of a spread and
            // leaves the one actually about to be shown cold.
            let spreads = spreads(pageCount: pageCount, wideIndices: wideIndices, offsetCover: offsetCover)
            guard !spreads.isEmpty else { return [] }
            let index = spreadIndex(containing: current, spreads: spreads)
            shown = Set(spreads[index])
            let ahead = spreads.indices.contains(index + 1) ? spreads[index + 1] : []
            let behind = spreads.indices.contains(index - 1) ? spreads[index - 1] : []
            candidates = ahead + behind
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
        let indices = Self.prefetchIndices(
            current: currentPageIndex,
            pageCount: pageURLs.count,
            mode: readingMode,
            wideIndices: wideIndices,
            offsetCover: offsetCover
        )
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
                //
                // Webtoon gets no overlay at all. A full-size `Color.clear`
                // with an `onTapGesture` was laid over the ScrollView to
                // toggle the controls, and it ate every scroll event before
                // the scroll view saw one: the trackpad did nothing in
                // webtoon mode, while keyboard scrolling still worked because
                // that arrives through the responder chain rather than as a
                // hit-tested gesture. Its tap now rides on the page rows
                // inside the scroll content, where a tap gesture and a scroll
                // coexist.
                .overlay {
                    if Self.inputMode(for: readingMode) == .pageTurn {
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
                    // The next chapter has to be warmed at the same fit or it
                    // is warmed into a cache slot this reader never reads.
                    ReaderBridge.shared.pageFit = plan.fit
                    prefetcher.replace(urls: plan.urls, fit: plan.fit) { url, size in
                        guard let index = pageURLs.firstIndex(of: url) else { return }
                        notePageSize(index: index, size: size)
                    }
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

            if syncToast {
                VStack {
                    Spacer()
                    syncedBadge
                        .padding(.bottom, showControls ? 72 : 24)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .focusable()
        .focused($isFocused)
        // The focus above exists only so the arrow keys below reach this
        // view; without this the system also drew its default focus ring,
        // a blue rectangle around the entire reader for as long as it was
        // open.
        .focusEffectDisabled()
        // `.ignored` rather than `.handled` in webtoon mode: `.handled`
        // swallows the key even when nothing acts on it, and the scroll view
        // gets its arrow-key scrolling through that same responder chain.
        .onKeyPress(.leftArrow) {
            guard Self.inputMode(for: readingMode) == .pageTurn else { return .ignored }
            turnPage(forward: readingDirection == .rtl)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard Self.inputMode(for: readingMode) == .pageTurn else { return .ignored }
            turnPage(forward: readingDirection == .ltr)
            return .handled
        }
        // A chapter turn replaces the page list without replacing the view:
        // RootView keeps one `if let session` branch with no `.id`, so this
        // view's identity survives and `State(initialValue: initialPage)` is
        // honoured only on the first chapter. Left alone, the next chapter
        // opened at the page the last one ended on — blank when it was
        // shorter — and counted as finished the instant it appeared.
        .onChange(of: pageURLs) { _, _ in
            currentPageIndex = 0
            wideIndices = []
            lastTurnWasForward = true
            didPreloadNextChapter = false
            didFinishChapter = false
            syncToast = false
            noteReadingPosition(0)
        }
        .onChange(of: readingMode) { _, mode in
            ReaderPreferences.setMode(mode, catalogId: catalogId)
            updateSwipeMonitor()
        }
        .onChange(of: readingDirection) { _, direction in
            ReaderPreferences.setRightToLeft(direction == .rtl, catalogId: catalogId)
        }
        .onChange(of: offsetCover) { _, offset in
            ReaderPreferences.setOffsetsCover(offset, catalogId: catalogId)
        }
        .onAppear {
            isFocused = true
            updateSwipeMonitor()
            // A one-page chapter is finished the moment it opens and is never
            // turned, so the threshold checks have to run once without a turn
            // or such a chapter would never sync.
            noteReadingPosition(currentPageIndex)
            #if os(macOS)
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                wasFullScreenBeforeOpen = window.styleMask.contains(.fullScreen)
                if !wasFullScreenBeforeOpen {
                    FullScreenGuard.toggle(on: window)
                }
            }
            #endif
        }
        .onDisappear {
            prefetcher.cancel()
            swipeMonitor.stop()
            #if os(macOS)
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                if window.styleMask.contains(.fullScreen) && !wasFullScreenBeforeOpen {
                    FullScreenGuard.toggle(on: window)
                }
            }
            #endif
        }
    }

    /// The trackpad swipe belongs to the paged modes only: webtoon *is* a
    /// scroll view, and consuming its horizontal scroll would be the same
    /// mistake as the overlay that used to swallow the vertical one.
    private func updateSwipeMonitor() {
        guard Self.inputMode(for: readingMode) == .pageTurn else {
            swipeMonitor.stop()
            return
        }
        swipeMonitor.start { rightward in
            turnPage(forward: (readingDirection == .rtl) == rightward)
        }
    }

    private var syncedBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.success)
            Text("Synced to AniList")
                .sumiTabularMono(size: 11, weight: .medium)
                .foregroundColor(SumiTheme.foreground)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(SumiTheme.card.opacity(0.95))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
    }

    private func exitReader() {
        #if os(macOS)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            if window.styleMask.contains(.fullScreen) && !wasFullScreenBeforeOpen {
                FullScreenGuard.toggle(on: window)
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
                    ReaderPageImage(url: url, fit: fit, onDecoded: { notePageSize(index: index, size: $0) }) {
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
                    // The controls toggle lives on the row rather than on an
                    // overlay above the ScrollView, which is what used to
                    // swallow the trackpad. `contentShape` because the loaded
                    // page is aspect-fitted and does not fill the row it is
                    // drawn in, so the letterboxed strip either side would
                    // otherwise not be tappable.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.smooth) { showControls.toggle() }
                    }
                    .onAppear {
                        currentPageIndex = index
                        onPageChanged(index)
                        noteReadingPosition(index)
                    }
                }
            }
            .frame(maxWidth: Self.webtoonMaxWidth)
        }
    }

    // MARK: - Single Page View
    private func singlePageView(fit: ImageFit) -> some View {
        // The ZStack is what lets the outgoing and incoming page occupy the
        // frame together for the length of the crossfade; in a plain `if` the
        // old page is gone before the new one is laid out and the transition
        // has nothing to cross into.
        ZStack {
            if pageURLs.indices.contains(currentPageIndex) {
                page(at: currentPageIndex, fit: fit)
                    .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Double Page View
    private func doublePageView(fit: ImageFit) -> some View {
        ZStack {
            let pages = visiblePages
            if !pages.isEmpty {
                HStack(spacing: Self.spreadSpacing) {
                    // Reading order is applied here and nowhere else: the
                    // spread is a list of pages in page order, and a
                    // right-to-left book simply draws that list mirrored.
                    ForEach(readingDirection == .rtl ? pages.reversed() : pages, id: \.self) { index in
                        page(at: index, fit: fit)
                    }
                }
                // Keyed on the spread, so a turn transitions the pair as one
                // unit. Keying the two pages individually crossfaded them out
                // of step and, in an HStack, moved the surviving one sideways
                // while the other faded.
                .id(pages)
                .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keyed on the URL so a turn builds a fresh view. With one identity
    /// across turns, `State(initialValue:)` in the page's init is honored only
    /// once, so the prefetched page's synchronous cache hit never reached the
    /// first frame, and a turn to a page not yet fetched left the *previous*
    /// page on screen with nothing acknowledging the key press.
    private func page(at index: Int, fit: ImageFit) -> some View {
        ReaderPageImage(
            url: pageURLs[index],
            fit: fit,
            onDecoded: { notePageSize(index: index, size: $0) }
        ) {
            ProgressView()
        } failure: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(SumiTheme.warning)
        }
        .id(pageURLs[index])
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
                if let window = NSApp.keyWindow ?? NSApp.mainWindow { FullScreenGuard.toggle(on: window) }
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

            // Only meaningful while pages are being paired, and a toggle that
            // changes nothing visible is worse than an absent one.
            if readingMode == .double {
                Button(action: { offsetCover.toggle() }) {
                    Label("Offset cover", systemImage: offsetCover ? "book.closed.fill" : "book.closed")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                        .foregroundColor(offsetCover ? SumiTheme.background : SumiTheme.muted)
                        .frame(width: 32, height: 32)
                        .background(offsetCover ? SumiTheme.indigo : SumiTheme.card.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.sumiPressable)
                .help("Show the first page alone so the spreads after it match the printed pairing.")
                .animation(.snappy, value: offsetCover)
                .padding(.trailing, 4)
            }

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

    /// Names both pages of a spread rather than only its first: "Page 11 / 40"
    /// while pages 11 and 12 are on screen is a readout that disagrees with
    /// what the reader can see.
    private var pageReadout: String {
        let total = max(pageURLs.count, 1)
        let pages = visiblePages
        guard let first = pages.first else { return "Page 1 / \(total)" }
        if let last = pages.last, last != first {
            return "Pages \(first + 1)-\(last + 1) / \(total)"
        }
        return "Page \(first + 1) / \(total)"
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

            Text(pageReadout)
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
    /// The decoded pixel size, which is where the reader learns a page's
    /// aspect. A decode is aspect-fitted into the box, so the ratio is the
    /// source's even though the size is not.
    let onDecoded: (CGSize) -> Void
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var phase: Phase

    init(
        url: URL,
        fit: ImageFit,
        onDecoded: @escaping (CGSize) -> Void = { _ in },
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.fit = fit
        self.onDecoded = onDecoded
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

    /// `Phase` holds a `CGImage`, which is not `Equatable`, so the size is
    /// pulled out into something `onChange` can compare.
    private struct LoadedSize: Equatable {
        let size: CGSize?

        init(phase: Phase) {
            if case .loaded(let image) = phase {
                size = CGSize(width: image.width, height: image.height)
            } else {
                size = nil
            }
        }
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
        // Reported from here rather than from the init's cache hit: a `View`
        // init runs during a body evaluation, and writing the reader's state
        // from one is the "Modifying state during view update" trap.
        .onChange(of: LoadedSize(phase: phase), initial: true) { _, loaded in
            if let size = loaded.size { onDecoded(size) }
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
///
/// Sequential, one page at a time, for the reason `ImageDecodeCache.prefetch`
/// gives: three concurrent page fetches share the connection with the page the
/// reader is waiting on. This drives the loop itself rather than calling that
/// helper only so each page's decoded size can be reported as it lands — which
/// is how a wide page is discovered before its spread is reached instead of
/// when it is drawn. The loop awaits and does no work of its own; the fetch and
/// the decode still run detached, at `.utility`, behind anything visible.
@MainActor
final class PagePrefetcher {
    private var task: Task<Void, Never>?

    func replace(urls: [URL], fit: ImageFit, onDecoded: @escaping (URL, CGSize) -> Void) {
        task?.cancel()
        guard !urls.isEmpty else {
            task = nil
            return
        }
        task = Task {
            for url in urls {
                guard !Task.isCancelled else { return }
                guard let image = await ImageDecodeCache.shared.image(for: url, fit: fit, priority: .utility)
                else { continue }
                guard !Task.isCancelled else { return }
                onDecoded(url, CGSize(width: image.width, height: image.height))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Trackpad swipe

/// Horizontal two-finger trackpad swipe as a page turn.
///
/// A swipe over a view that does not scroll arrives as `.scrollWheel` events,
/// never as a `DragGesture` — SwiftUI's drag wants a pressed pointer — so a
/// flick over the paged modes did nothing at all. The deltas are accumulated
/// against a threshold and the momentum tail is dropped: one flick delivers
/// dozens of events and then coasts, and acting on each of them turned five
/// spreads on a single swipe.
@MainActor
final class TrackpadSwipeMonitor {
    /// Points of horizontal travel a turn costs. Low enough for a flick, high
    /// enough that the sideways drift in a two-finger vertical scroll does not
    /// reach it.
    static let threshold: CGFloat = 40

    private var monitor: Any?
    private var accumulated: CGFloat = 0

    func start(_ onSwipe: @escaping (Bool) -> Void) {
        stop()
        #if os(macOS)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // The coast after the fingers lift. Reading it turns pages the
            // reader has already stopped asking for.
            guard event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.began) { self.accumulated = 0 }
            // A vertical scroll is not this gesture's business, and the reader
            // pinches and scrolls with the same two fingers.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            self.accumulated += event.scrollingDeltaX
            if abs(self.accumulated) >= Self.threshold {
                onSwipe(self.accumulated > 0)
                self.accumulated = 0
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.accumulated = 0 }
            return nil
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
        monitor = nil
        accumulated = 0
    }
}
