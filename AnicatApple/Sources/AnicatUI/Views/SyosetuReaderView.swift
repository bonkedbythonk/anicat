import SwiftUI
import AnicatCoreKit

/// Reads a Syosetu (ncode.syosetu.com) light novel from a pasted URL —
/// see `AppModel.SyosetuSession`'s comment for why this is a direct-URL
/// flow rather than something reached from an AniList detail page.
public struct SyosetuReaderView: View {
    @Bindable var model: AppModel
    @State private var urlField: String = ""
    @State private var showToc = false
    /// The contents column beside the text, on a window wide enough for it.
    /// Narrower windows and the phone open the contents as a sheet instead.
    @State private var showSidebar = true
    @State private var showTypography = false
    @State private var typography = NovelPreferences.typography()
    /// Which paragraphs are on screen. The smallest of them is the reading
    /// position: it is what the progress bar measures and what is restored on
    /// reopening. A set rather than a running maximum because scrolling back
    /// up has to move the position back up with it — a bar that only ever
    /// advances stops describing where the reader is.
    @State private var visibleParagraphs: Set<Int> = []
    @State private var topParagraph = 0
    /// Suppresses position writes while a saved position is being scrolled
    /// back to. A LazyVStack builds from the top, so the rows that exist
    /// before and during the scroll report paragraph 0 as the topmost one —
    /// saved unguarded, that erased the position on the way to restoring it.
    @State private var isRestoring = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The scroll restore has to wait for the paragraphs to exist, and a
    /// LazyVStack builds them during the first layout pass after the text
    /// lands. Scrolling in the same turn as the assignment lands on a column
    /// that is still one row tall and does nothing.
    private static let restoreDelay: Duration = .milliseconds(80)

    /// The chapter heading's scroll id. Negative so it cannot collide with a
    /// paragraph index.
    private static let topAnchor = -1

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let session = model.syosetuSession {
                readerBody(session)
            } else {
                urlEntry
            }
        }
        // An overlay, not a sheet any more, so it has to paint its own ground
        // and take the whole window -- prose in a 560pt box with the app
        // showing around it was the thing to get rid of.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ground fills the screen on both platforms; only the Mac lets
        // the content under the title strip too. On the phone an ignored
        // safe area put the header under the Dynamic Island.
        .background(SumiTheme.background.ignoresSafeArea())
        #if os(macOS)
        .ignoresSafeArea()
        #endif
    }

    private var urlEntry: some View {
        SumiPage {
            // The reading body has its own Close; the entry screen had none
            // and relied on Escape, which a phone does not have.
            HStack {
                SumiOutlineButton("Close", systemImage: "xmark", action: model.closeSyosetuReader)
                Spacer()
            }
            SumiPageHeader(title: "Read a Light Novel", subtitle: "Paste a Syosetu link")
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a novel or chapter link from ncode.syosetu.com — the whole table of contents loads from it.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                HStack {
                    TextField("https://ncode.syosetu.com/n2267be/", text: $urlField)
                        #if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onSubmit(load)
                        // The phone keyboard capitalised the first letter,
                        // and the engine's origin regex is case-sensitive:
                        // "Https://" loaded the table of contents (the
                        // fetch does not care) and then every chapter href
                        // came back root-relative and was refused as "not
                        // a syosetu.com URL".
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    Button(action: load) {
                        Label("Open", anicat: "book").fontWeight(.semibold)
                    }
                    .sumiPrimaryButton()
                    .disabled(urlField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let last = NovelPreferences.lastNovel() {
                    SumiOutlineButton("Continue chapter \(last.chapter + 1) of \(last.title)", systemImage: "arrow.right") {
                        // By source, not by URL alone. `openSyosetuReader`
                        // goes to `novelInfo`, which refuses anything that is
                        // not a syosetu.com URL, so an lnori volume resumed
                        // into an error rather than into the book.
                        if last.source == AppModel.NovelSource.lnori.rawValue {
                            model.openLightNovelVolume(
                                bookURL: last.url,
                                title: last.title,
                                catalogId: last.catalogId
                            )
                        } else {
                            model.openSyosetuReader(url: last.url)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 12)
        }
    }

    private func load() {
        let trimmed = urlField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.openSyosetuReader(url: trimmed)
    }

    private var paragraphs: [String] {
        model.syosetuSession?.chapterText.components(separatedBy: "\n\n") ?? []
    }

    private var illustrations: [NovelImage] {
        model.syosetuSession?.chapterImages ?? []
    }

    /// Below this the text column and a 240pt contents column do not both
    /// fit at a readable width.
    private static let sidebarMinWidth: CGFloat = 900
    private static let sidebarWidth: CGFloat = 240

    @ViewBuilder
    private func readerBody(_ session: AppModel.SyosetuSession) -> some View {
        GeometryReader { geo in
            let wide = Self.allowsSidebar && geo.size.width >= Self.sidebarMinWidth
            HStack(spacing: 0) {
                if wide && showSidebar {
                    contentsSidebar(session)
                        .frame(width: Self.sidebarWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(divider).frame(width: 1)
                        }
                }
                readerColumn(session, wide: wide)
            }
        }
        .background(typography.theme.background)
        .focusable()
        // Same reason as the manga reader: the focus exists only so the arrow
        // keys below arrive, and the system's default ring around the whole
        // reader is not a wanted side effect of asking for it.
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            jump(session, by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            jump(session, by: 1)
            return .handled
        }
        .onChange(of: typography) { _, settings in
            NovelPreferences.setTypography(settings)
        }
        .sheet(isPresented: $showToc) {
            tocSheet(session)
        }
    }

    /// The Mac only: no phone is 900pt wide, and beside a 240pt column the
    /// text on one would be a few words to a line.
    private static var allowsSidebar: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Hairline in the page theme's own ink, so it holds on Sepia and Paper
    /// as well as on the app's ground.
    private var divider: Color { typography.theme.muted.opacity(0.18) }

    private func readerColumn(_ session: AppModel.SyosetuSession, wide: Bool) -> some View {
        VStack(spacing: 0) {
            header(session, wide: wide)
            Rectangle().fill(divider).frame(height: 1)

            Group {
                if let error = session.errorMessage {
                    SumiEmptyState(headline: "Could not load", detail: error)
                        .frame(maxHeight: .infinity)
                } else if session.isLoading && session.chapterText.isEmpty {
                    ProgressView().controlSize(.large).frame(maxHeight: .infinity)
                } else {
                    chapterText(session)
                }
            }
            // The spinner snapped straight to the first chapter's text.
            // `.id` because these are a conditional chain: a transition on
            // the enclosing `Group` never fires while the Group's own
            // identity is stable. Only the first load crosses here — a later
            // chapter keeps the previous text on screen while it fetches, so
            // this phase does not change and the ScrollView is not rebuilt.
            .sumiTransition(.opacity)
            .id(bodyPhase(session))
            .animation(.sumi(.page), value: bodyPhase(session))

            footer(session)
        }
    }

    private func sidebarHeading(_ session: AppModel.SyosetuSession) -> String {
        let chapters = session.info?.chapters ?? []
        guard chapters.indices.contains(session.currentChapterIndex),
              let volume = chapters[session.currentChapterIndex].volumeName else { return "Contents" }
        return "\(volume) · Contents"
    }

    /// The table of contents as a column, the current chapter marked. Scrolls
    /// itself to the open chapter, which in a long web novel would otherwise
    /// sit far below the fold.
    private func contentsSidebar(_ session: AppModel.SyosetuSession) -> some View {
        let chapters = session.info?.chapters ?? []
        return VStack(alignment: .leading, spacing: 0) {
            Text(sidebarHeading(session))
                .sumiTabularMono(size: 11.5)
                .foregroundColor(typography.theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            contentsRow(chapter.title, isOn: index == session.currentChapterIndex) {
                                Task { await model.loadSyosetuChapter(url: chapter.url, index: index) }
                            }
                            .id(index)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .onAppear { proxy.scrollTo(session.currentChapterIndex, anchor: .center) }
                .onChange(of: session.currentChapterIndex) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .padding(.top, 20)
        // The column runs to the top of the window, under the transparent
        // title strip, which would otherwise eat clicks on the first rows.
        #if os(macOS)
        .padding(.top, Self.titleStripHeight)
        #endif
    }

    private func contentsRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                .foregroundColor(isOn ? typography.theme.foreground : typography.theme.muted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    SumiRect(cornerRadius: SumiTheme.radiusSm)
                        .fill(isOn ? typography.theme.foreground.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .padding(.horizontal, 8)
    }

    /// Which of the three states the reader body is in, so one
    /// `.animation(value:)` can watch the swap between them.
    private func bodyPhase(_ session: AppModel.SyosetuSession) -> Int {
        if session.errorMessage != nil { return 0 }
        if session.isLoading && session.chapterText.isEmpty { return 1 }
        return 2
    }

    private func chapterText(_ session: AppModel.SyosetuSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: typography.paragraphSpacing) {
                    Text(session.chapterTitle)
                        .font(typography.font(size: typography.fontSize + 4, weight: .semibold))
                        .foregroundColor(typography.theme.foreground)
                        .padding(.bottom, 4)
                        // The heading sits above paragraph 0, so scrolling to
                        // paragraph 0 is not the top of the chapter -- it puts
                        // the title just off screen, which is what a chapter
                        // opened with Next looked like.
                        .id(Self.topAnchor)
                    // A machine-translation pass would sit here, between the
                    // chapter text arriving and it being laid out: one
                    // translated string per paragraph, with the original kept
                    // so the two can be shown together. Deliberately not
                    // built — Syosetu text is the raw Japanese and a wrong
                    // translation reads as a real sentence.
                    // Before any prose: a colour-inserts section is nothing
                    // but these, which is why it used to render as a blank
                    // page.
                    illustrationStack(after: -1)
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        VStack(alignment: .leading, spacing: typography.paragraphSpacing) {
                            Text(paragraph.isEmpty ? " " : paragraph)
                                .font(typography.font())
                                .lineSpacing(typography.lineSpacing)
                                .foregroundColor(typography.theme.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            illustrationStack(after: index)
                        }
                        .id(index)
                        .onAppear { markVisible(index, visible: true) }
                        .onDisappear { markVisible(index, visible: false) }
                    }
                }
                .frame(maxWidth: typography.columnWidth)
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            // Keyed on the chapter text rather than the index so a reopen of
            // the same chapter restores too, and so a chapter that fails and
            // is retried does not scroll into a column that never arrived.
            .task(id: session.chapterText) {
                guard !session.chapterText.isEmpty else { return }
                let saved = NovelPreferences.position(
                    sourceURL: session.sourceURL,
                    chapter: session.currentChapterIndex
                )
                visibleParagraphs = []
                topParagraph = saved
                isRestoring = true
                defer { isRestoring = false }
                // Always, even with nothing saved. The ScrollView is not
                // rebuilt between chapters -- only its text changes -- so it
                // keeps the offset it had, and Next from halfway down a
                // chapter opened the next one already halfway down.
                proxy.scrollTo(Self.topAnchor, anchor: .top)
                guard saved > 0 else { return }
                try? await Task.sleep(for: Self.restoreDelay)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(saved, anchor: .top)
                // A second wait for the rows the scroll passed over to settle:
                // they report themselves as they go, and until they have, the
                // topmost visible paragraph is still the top of the chapter.
                try? await Task.sleep(for: Self.restoreDelay)
            }
        }
    }

    /// The illustrations that follow one paragraph, in the order the page put
    /// them in.
    @ViewBuilder
    private func illustrationStack(after index: Int) -> some View {
        let matching = illustrations.filter { Int($0.afterParagraph) == index }
        if !matching.isEmpty {
            VStack(spacing: typography.paragraphSpacing) {
                ForEach(matching, id: \.url) { illustration($0) }
            }
            .padding(.vertical, 4)
        }
    }

    private func illustration(_ image: NovelImage) -> some View {
        // A downloaded volume hands back a plain path, not a `file://`
        // string: Application Support has a space in it and `URL(string:)`
        // answers nil for that, so every stored illustration would silently
        // fail to draw.
        let url = image.url.hasPrefix("http")
            ? URL(string: image.url)
            : URL(fileURLWithPath: image.url)
        return CachedAsyncImage(url: url, fit: .maxPixelSize(1400)) { rendered in
            rendered
                .resizable()
                .scaledToFit()
                .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
        } placeholder: {
            SumiRect(cornerRadius: SumiTheme.radiusSm)
                .fill(typography.theme.foreground.opacity(0.06))
                .frame(height: 260)
                .overlay(ProgressView().controlSize(.small))
        }
        .frame(maxWidth: .infinity)
    }

    private func markVisible(_ index: Int, visible: Bool) {
        if visible {
            visibleParagraphs.insert(index)
        } else {
            visibleParagraphs.remove(index)
        }
        // A LazyVStack can briefly hold nothing while it swaps a row out and
        // the next one in; taking the minimum of an empty set would snap the
        // position to zero and save it there.
        guard !isRestoring, let top = visibleParagraphs.min(), top != topParagraph else { return }
        topParagraph = top
        guard let session = model.syosetuSession else { return }
        NovelPreferences.setPosition(
            top,
            sourceURL: session.sourceURL,
            chapter: session.currentChapterIndex
        )
    }

    /// How far through the open chapter the reader is: a 2pt line in the
    /// footer beside the chapter counter, a readout rather than a control.
    private var progressBar: some View {
        GeometryReader { geo in
            let total = max(paragraphs.count - 1, 1)
            let fraction = min(Double(topParagraph) / Double(total), 1)
            Rectangle()
                .fill(SumiTheme.indigo)
                .frame(width: geo.size.width * fraction)
                .animation(reduceMotion ? nil : .snappy, value: fraction)
        }
        .frame(height: 2)
        .background(divider)
    }

    private func header(_ session: AppModel.SyosetuSession, wide: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: model.closeSyosetuReader) {
                Image(anicat: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(typography.theme.foreground.opacity(0.8))
                    .frame(width: Self.glyphHit, height: Self.glyphHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Close the reader")

            VStack(alignment: .leading, spacing: 2) {
                Text(session.info?.title ?? "")
                    .font(.sumiHeading(size: 13, weight: .semibold))
                    .foregroundColor(typography.theme.foreground)
                    .lineLimit(1)
                Text(headerMeta(session))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(typography.theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SumiOutlineButton("Contents") {
                if wide {
                    withAnimation(.snappy) { showSidebar.toggle() }
                } else {
                    showToc = true
                }
            }
            .disabled(session.info == nil)
            SumiOutlineButton("Aa") { showTypography = true }
                .help("Reader settings")
                .sumiPopover(isPresented: $showTypography, arrowEdge: .bottom) {
                    typographyPopover
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // Below the title strip, not beside it. The reader fills the window,
        // so its own bar starts where the window's does -- and that strip is
        // not merely where the traffic lights are drawn, it is a region that
        // takes the click: the top half of Close (y 14 to 28) did nothing at
        // all, while the half below the strip closed the reader.
        #if os(macOS)
        .padding(.top, Self.titleStripHeight)
        #endif
    }

    /// "Chapter 7 · Author", the author dropped when the source gave none
    /// (an lnori volume never does).
    private func headerMeta(_ session: AppModel.SyosetuSession) -> String {
        let chapter = "Chapter \(session.currentChapterIndex + 1)"
        guard let author = session.info?.author, !author.isEmpty else { return chapter }
        return "\(chapter) · \(author)"
    }

    /// 28pt is a pointer target; on the phone the close button needs a
    /// thumb's 44.
    #if os(iOS)
    private static let glyphHit: CGFloat = 44
    #else
    private static let glyphHit: CGFloat = 28
    #endif

    /// The height AppKit's transparent title bar occupies over the content,
    /// matching `TitleStripDoubleClick.stripHeight` in the app target.
    static let titleStripHeight: CGFloat = 28

    private var typographyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Face") {
                SumiSlashToggle(NovelTypography.Family.allCases.map { ($0, $0.label) }, selection: typography.family) {
                    typography.family = $0
                }
            }
            row("Size") {
                HStack(spacing: 8) {
                    SumiOutlineButton("A\u{2212}") { stepFontSize(by: -1) }
                        .disabled(typography.fontSize <= NovelTypography.fontSizeRange.lowerBound)
                    Text(String(format: "%.0f", typography.fontSize))
                        .sumiTabularMono(size: 12.5)
                        .foregroundColor(SumiTheme.foreground)
                        .frame(minWidth: 20)
                    SumiOutlineButton("A+") { stepFontSize(by: 1) }
                        .disabled(typography.fontSize >= NovelTypography.fontSizeRange.upperBound)
                }
            }
            row("Line width") {
                SumiSlashToggle(
                    NovelTypography.lineWidths.map { ($0.width, $0.label) },
                    selection: typography.nearestLineWidth
                ) {
                    typography.columnWidth = $0
                }
            }
            row("Page") {
                SumiSlashToggle(NovelTypography.PageTheme.allCases.map { ($0, $0.label) }, selection: typography.theme) {
                    typography.theme = $0
                }
            }
            slider("Line height", value: $typography.lineHeight, range: NovelTypography.lineHeightRange, step: 0.05, format: "%.2f")
            slider("Paragraph gap", value: $typography.paragraphSpacing, range: NovelTypography.paragraphSpacingRange, step: 1, format: "%.0f pt")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    private func stepFontSize(by delta: Double) {
        typography.fontSize = (typography.fontSize + delta).clamped(to: NovelTypography.fontSizeRange)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundColor(SumiTheme.foreground)
            Spacer(minLength: 12)
            control()
        }
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundColor(SumiTheme.foreground)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
            // The reader is not on the TV; `Slider` is not in its SDK.
            #if !os(tvOS)
            Slider(value: value, in: range, step: step)
            #endif
        }
    }

    private func footer(_ session: AppModel.SyosetuSession) -> some View {
        HStack(spacing: 14) {
            if let info = session.info {
                Text("Chapter \(session.currentChapterIndex + 1) of \(info.chapters.count)")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(typography.theme.muted)
                    .fixedSize()
            }
            progressBar
            Button {
                jump(session, by: -1)
            } label: {
                Text("Previous").sumiTabularMono(size: 11.5, weight: .medium)
            }
            .disabled(session.currentChapterIndex <= 0)
            Button {
                jump(session, by: 1)
            } label: {
                Text("Next").sumiTabularMono(size: 11.5, weight: .medium)
            }
            .disabled((session.info?.chapters.count ?? 0) <= session.currentChapterIndex + 1)
        }
        .foregroundColor(typography.theme.foreground)
        .buttonStyle(.sumiPressable)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func jump(_ session: AppModel.SyosetuSession, by delta: Int) {
        guard let chapters = session.info?.chapters else { return }
        let target = session.currentChapterIndex + delta
        guard chapters.indices.contains(target) else { return }
        Task { await model.loadSyosetuChapter(url: chapters[target].url, index: target) }
    }

    private func tocSheet(_ session: AppModel.SyosetuSession) -> some View {
        NavigationStack {
            List {
                ForEach(Array((session.info?.chapters ?? []).enumerated()), id: \.offset) { index, chapter in
                    Button {
                        showToc = false
                        Task { await model.loadSyosetuChapter(url: chapter.url, index: index) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let volume = chapter.volumeName {
                                Text(volume).sumiTabularMono(size: 10).foregroundColor(SumiTheme.muted)
                            }
                            Text(chapter.title)
                                .foregroundColor(index == session.currentChapterIndex ? SumiTheme.indigo : SumiTheme.foreground)
                        }
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            .navigationTitle("Table of Contents")
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}
