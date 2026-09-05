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
    @FocusState private var isFocused: Bool

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

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            // Page Render Content
            Group {
                switch readingMode {
                case .webtoon:
                    webtoonView
                case .single:
                    singlePageView
                case .double:
                    doublePageView
                }
            }
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
    private var webtoonView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(pageURLs.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        case .empty:
                            Rectangle()
                                .fill(SumiTheme.card)
                                .frame(height: 600)
                                .overlay(ProgressView())
                        case .failure:
                            Rectangle()
                                .fill(SumiTheme.card)
                                .frame(height: 300)
                                .overlay(
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(SumiTheme.warning)
                                )
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .id(index)
                    .onAppear {
                        currentPageIndex = index
                        onPageChanged(index)
                    }
                }
            }
            .frame(maxWidth: 800)
        }
    }

    // MARK: - Single Page View
    private var singlePageView: some View {
        ZStack {
            if pageURLs.indices.contains(currentPageIndex) {
                AsyncImage(url: pageURLs[currentPageIndex]) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        ProgressView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Double Page View
    private var doublePageView: some View {
        HStack(spacing: 4) {
            let leftIndex = readingDirection == .rtl ? currentPageIndex + 1 : currentPageIndex
            let rightIndex = readingDirection == .rtl ? currentPageIndex : currentPageIndex + 1

            if pageURLs.indices.contains(leftIndex) {
                AsyncImage(url: pageURLs[leftIndex]) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    }
                }
            }
            
            if pageURLs.indices.contains(rightIndex) {
                AsyncImage(url: pageURLs[rightIndex]) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    }
                }
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
