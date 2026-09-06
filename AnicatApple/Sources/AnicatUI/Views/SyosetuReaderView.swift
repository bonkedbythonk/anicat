import SwiftUI

/// Reads a Syosetu (ncode.syosetu.com) light novel from a pasted URL —
/// see `AppModel.SyosetuSession`'s comment for why this is a direct-URL
/// flow rather than something reached from an AniList detail page.
public struct SyosetuReaderView: View {
    @Bindable var model: AppModel
    @State private var urlField: String = ""
    @State private var showToc = false
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
    }

    private var urlEntry: some View {
        SumiPage {
            SumiPageHeader(title: "Read a Light Novel", subtitle: "PASTE A SYOSETU LINK")
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a novel or chapter link from ncode.syosetu.com — the whole table of contents loads from it.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                HStack {
                    TextField("https://ncode.syosetu.com/n2267be/", text: $urlField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(load)
                    SumiOutlineButton("Open", systemImage: "book", action: load)
                        .disabled(urlField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let last = NovelPreferences.lastNovel() {
                    SumiOutlineButton("Continue chapter \(last.chapter + 1) of \(last.title)", systemImage: "arrow.right") {
                        model.openSyosetuReader(url: last.url)
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

    @ViewBuilder
    private func readerBody(_ session: AppModel.SyosetuSession) -> some View {
        VStack(spacing: 0) {
            header(session)
            progressBar
            Divider().background(SumiTheme.border.opacity(0.4))

            if let error = session.errorMessage {
                SumiEmptyState(headline: "Could not load", detail: error)
                    .frame(maxHeight: .infinity)
            } else if session.isLoading && session.chapterText.isEmpty {
                ProgressView().controlSize(.large).frame(maxHeight: .infinity)
            } else {
                chapterText(session)
            }

            footer(session)
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

    private func chapterText(_ session: AppModel.SyosetuSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: typography.paragraphSpacing) {
                    Text(session.chapterTitle)
                        .font(typography.font(size: typography.fontSize + 4, weight: .semibold))
                        .foregroundColor(typography.theme.foreground)
                        .padding(.bottom, 4)
                    // A machine-translation pass would sit here, between the
                    // chapter text arriving and it being laid out: one
                    // translated string per paragraph, with the original kept
                    // so the two can be shown together. Deliberately not
                    // built — Syosetu text is the raw Japanese and a wrong
                    // translation reads as a real sentence.
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph.isEmpty ? " " : paragraph)
                            .font(typography.font())
                            .lineSpacing(typography.lineSpacing)
                            .foregroundColor(typography.theme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .onAppear { markVisible(index, visible: true) }
                            .onDisappear { markVisible(index, visible: false) }
                    }
                }
                .frame(maxWidth: typography.columnWidth)
                .padding(32)
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
                guard saved > 0 else { return }
                isRestoring = true
                defer { isRestoring = false }
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

    /// How far through the open chapter the reader is. Two points tall and
    /// under the header rather than in it: it is a place-in-the-page readout,
    /// not a control, and the chapter counter in the footer is what answers
    /// "where am I in the book".
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
        .background(typography.theme.muted.opacity(0.18))
    }

    private func header(_ session: AppModel.SyosetuSession) -> some View {
        HStack {
            SumiOutlineButton("Close", systemImage: "xmark", action: model.closeSyosetuReader)
            Spacer()
            VStack(spacing: 2) {
                Text(session.info?.title ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(typography.theme.foreground)
                    .lineLimit(1)
                if let author = session.info?.author {
                    Text(author).sumiTabularMono(size: 10.5).foregroundColor(typography.theme.muted)
                }
            }
            Spacer()
            SumiOutlineButton("Aa", systemImage: "textformat.size", action: { showTypography = true })
                .popover(isPresented: $showTypography, arrowEdge: .bottom) {
                    typographyPopover
                }
            SumiOutlineButton("Chapters", systemImage: "list.bullet", action: { showToc = true })
                .disabled(session.info == nil)
        }
        .padding(12)
    }

    private var typographyPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider("Size", value: $typography.fontSize, range: NovelTypography.fontSizeRange, step: 1, format: "%.0f pt")
            slider("Line height", value: $typography.lineHeight, range: NovelTypography.lineHeightRange, step: 0.05, format: "%.2f")
            slider("Column", value: $typography.columnWidth, range: NovelTypography.columnWidthRange, step: 10, format: "%.0f pt")
            slider("Paragraph gap", value: $typography.paragraphSpacing, range: NovelTypography.paragraphSpacingRange, step: 1, format: "%.0f pt")

            picker("Typeface", selection: $typography.family, options: NovelTypography.Family.allCases) { $0.label }
            picker("Page", selection: $typography.theme, options: NovelTypography.PageTheme.allCases) { $0.label }
        }
        .padding(16)
        .frame(width: 320)
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
                Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(SumiTheme.foreground)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func picker<Option: Hashable & Identifiable>(
        _ label: String,
        selection: Binding<Option>,
        options: [Option],
        title: @escaping (Option) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(SumiTheme.foreground)
            HStack(spacing: 4) {
                ForEach(options) { option in
                    Button { selection.wrappedValue = option } label: {
                        Text(title(option))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(selection.wrappedValue == option ? SumiTheme.background : SumiTheme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selection.wrappedValue == option ? SumiTheme.indigo : SumiTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: selection.wrappedValue)
        }
    }

    private func footer(_ session: AppModel.SyosetuSession) -> some View {
        HStack {
            Button {
                jump(session, by: -1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(session.currentChapterIndex <= 0)

            Spacer()
            if let info = session.info {
                Text("\(session.currentChapterIndex + 1) / \(info.chapters.count)")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(typography.theme.muted)
            }
            Spacer()

            Button {
                jump(session, by: 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled((session.info?.chapters.count ?? 0) <= session.currentChapterIndex + 1)
        }
        .buttonStyle(.sumiPressable)
        .padding(12)
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
