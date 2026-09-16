// Everything the two readers remember between sessions, and the pure
// functions that decide what a stored value means. Kept out of the views so
// the key shapes can be tested without building a view hierarchy.

import Foundation
import SwiftUI

// MARK: - Manga reader

/// Per-title manga reader settings, with a global default underneath.
///
/// Per-title rather than global-only because a title's own shape decides the
/// answer: a Japanese release reads right to left and pairs into spreads, a
/// Korean webtoon is one vertical strip, and a reader who sets one of them up
/// does not want the next title they open to inherit it. The global key is
/// what a title that has never been opened starts from.
public enum ReaderPreferences {
    static let modeKey = "anicat_reader_mode"
    static let rtlKey = "anicat_reader_rtl"
    static let offsetCoverKey = "anicat_reader_offset_cover"
    static let syncedChapterKey = "anicat_reader_synced"

    /// `<key>_<catalogId>`, or the bare key when the reader was opened from
    /// somewhere with no AniList id attached (a MangaKatana-only title, or a
    /// chapter opened before the detail page resolved one). Falling back to
    /// the global key rather than to a fixed default means those titles at
    /// least share one setting instead of resetting on every open.
    static func key(_ base: String, catalogId: Int64?) -> String {
        guard let catalogId else { return base }
        return "\(base)_\(catalogId)"
    }

    /// Reads the per-title value, then the global one, then the supplied
    /// default. `object(forKey:)` and not `string`/`bool`, because "the key
    /// is absent" and "the key holds the default value" have to be told
    /// apart: `bool(forKey:)` returns false for both, which would make a
    /// global RTL default unreachable for every title never set explicitly.
    private static func stored(_ base: String, catalogId: Int64?, defaults: UserDefaults) -> Any? {
        if let catalogId, let perTitle = defaults.object(forKey: key(base, catalogId: catalogId)) {
            return perTitle
        }
        return defaults.object(forKey: base)
    }

    public static func mode(
        catalogId: Int64?,
        defaults: UserDefaults = .standard
    ) -> MangaReaderView.ReadingMode {
        guard let raw = stored(modeKey, catalogId: catalogId, defaults: defaults) as? String,
              let mode = MangaReaderView.ReadingMode(rawValue: raw) else { return .webtoon }
        return mode
    }

    public static func setMode(
        _ mode: MangaReaderView.ReadingMode,
        catalogId: Int64?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: key(modeKey, catalogId: catalogId))
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    public static func isRightToLeft(catalogId: Int64?, defaults: UserDefaults = .standard) -> Bool {
        stored(rtlKey, catalogId: catalogId, defaults: defaults) as? Bool ?? true
    }

    public static func setRightToLeft(_ rtl: Bool, catalogId: Int64?, defaults: UserDefaults = .standard) {
        defaults.set(rtl, forKey: key(rtlKey, catalogId: catalogId))
        defaults.set(rtl, forKey: rtlKey)
    }

    /// Whether the first page of a chapter is shown alone so every later
    /// spread lands on the pairing the book was drawn for.
    public static func offsetsCover(catalogId: Int64?, defaults: UserDefaults = .standard) -> Bool {
        stored(offsetCoverKey, catalogId: catalogId, defaults: defaults) as? Bool ?? false
    }

    public static func setOffsetsCover(_ offset: Bool, catalogId: Int64?, defaults: UserDefaults = .standard) {
        defaults.set(offset, forKey: key(offsetCoverKey, catalogId: catalogId))
        defaults.set(offset, forKey: offsetCoverKey)
    }

    /// The highest chapter number this title has already been synced to
    /// AniList for. Survives a relaunch on purpose: the "once per chapter"
    /// rule has to hold across the app being closed and the chapter reread,
    /// or a reread would fire a mutation on every page-turn to the last page.
    /// Not read as authority over AniList — the mutation still checks the
    /// live list progress first; this only stops the round trip being made.
    public static func syncedChapter(catalogId: Int64, defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key(syncedChapterKey, catalogId: catalogId))
    }

    public static func setSyncedChapter(_ chapter: Int, catalogId: Int64, defaults: UserDefaults = .standard) {
        guard chapter > syncedChapter(catalogId: catalogId, defaults: defaults) else { return }
        defaults.set(chapter, forKey: key(syncedChapterKey, catalogId: catalogId))
    }

    /// The integer AniList progress a chapter label implies.
    ///
    /// `MangaChapterItem.number` is provider text, not a number: MangaDex
    /// splits chapters ("12.5", "104.1") and `Int("12.5")` is nil, so parsing
    /// strictly meant a reader who finished a split chapter never synced at
    /// all. Flooring is also the right answer rather than merely a tolerant
    /// one — finishing 12.5 means 12 is behind you, and AniList progress is
    /// a whole number.
    public static func chapterProgress(from label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value >= 1, value.isFinite else { return nil }
        return Int(value.rounded(.down))
    }
}

// MARK: - Novel reader

/// The novel reader's typography, stored globally rather than per novel.
/// Font size and line height are a property of the reader's eyes, not of the
/// book, which is the opposite of the manga reader's per-title layout.
public struct NovelTypography: Equatable, Sendable {
    public enum Family: String, CaseIterable, Identifiable, Sendable {
        case serif
        case sans
        case geist

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .serif: return "Serif"
            case .sans: return "Sans"
            case .geist: return "Geist"
            }
        }
    }

    /// Applies inside the reader only. A novel read for an hour wants a page
    /// colour chosen for reading; the app around it keeps the one theme the
    /// rest of the design system is drawn against.
    public enum PageTheme: String, CaseIterable, Identifiable, Sendable {
        case ink
        case sepia
        case paper
        case oled

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .ink: return "Ink"
            case .sepia: return "Sepia"
            case .paper: return "Paper"
            case .oled: return "Black"
            }
        }

        public var background: Color {
            switch self {
            case .ink: return SumiTheme.background
            case .sepia: return Color(hex: "#F3E9D2")
            case .paper: return Color(hex: "#FBFAF6")
            case .oled: return .black
            }
        }

        public var foreground: Color {
            switch self {
            case .ink: return SumiTheme.foreground
            case .sepia: return Color(hex: "#4A3B2A")
            case .paper: return Color(hex: "#23201B")
            case .oled: return Color(hex: "#D2D2D2")
            }
        }

        public var muted: Color {
            switch self {
            case .ink: return SumiTheme.muted
            case .sepia: return Color(hex: "#8A7458")
            case .paper: return Color(hex: "#6E6A62")
            case .oled: return Color(hex: "#7A7A7A")
            }
        }
    }

    public var fontSize: Double = 17
    public var lineHeight: Double = 1.55
    public var columnWidth: Double = 680
    public var paragraphSpacing: Double = 14
    public var family: Family = .serif
    public var theme: PageTheme = .ink

    public static let fontSizeRange: ClosedRange<Double> = 14...24
    public static let lineHeightRange: ClosedRange<Double> = 1.3...1.9
    public static let columnWidthRange: ClosedRange<Double> = 560...900
    public static let paragraphSpacingRange: ClosedRange<Double> = 4...28

    /// SwiftUI's `lineSpacing` is the gap *added* between lines, not a
    /// multiple of the line box, so a 1.55 setting at 17pt is 9.35pt of
    /// spacing and not 26.35. Passing the multiple straight through opened
    /// paragraphs to roughly double the intended leading.
    public var lineSpacing: CGFloat { CGFloat(fontSize * (lineHeight - 1)) }

    public func font(size: Double? = nil, weight: Font.Weight = .regular) -> Font {
        let points = size ?? fontSize
        switch family {
        case .serif: return .system(size: points, weight: weight, design: .serif)
        case .sans: return .system(size: points, weight: weight)
        case .geist: return .sumiSans(size: points, weight: weight)
        }
    }
}

/// The `anicat_novel_*` keys: typography, per-chapter scroll position, and
/// which novel was last open.
public enum NovelPreferences {
    static let fontSizeKey = "anicat_novel_font_size"
    static let lineHeightKey = "anicat_novel_line_height"
    static let columnWidthKey = "anicat_novel_column_width"
    static let paragraphSpacingKey = "anicat_novel_paragraph_spacing"
    static let familyKey = "anicat_novel_family"
    static let themeKey = "anicat_novel_theme"
    static let positionKeyPrefix = "anicat_novel_pos"
    static let lastNovelURLKey = "anicat_novel_last_url"
    static let lastNovelTitleKey = "anicat_novel_last_title"
    static let lastNovelChapterKey = "anicat_novel_last_chapter"
    static let lastNovelSourceKey = "anicat_novel_last_source"
    static let lastNovelCatalogIdKey = "anicat_novel_last_catalog_id"

    public static func typography(defaults: UserDefaults = .standard) -> NovelTypography {
        var settings = NovelTypography()
        // Each read falls back to the struct's own default rather than to a
        // literal, so a key that was never written and a key holding zero do
        // not both produce a 0pt font.
        if let size = defaults.object(forKey: fontSizeKey) as? Double {
            settings.fontSize = size.clamped(to: NovelTypography.fontSizeRange)
        }
        if let height = defaults.object(forKey: lineHeightKey) as? Double {
            settings.lineHeight = height.clamped(to: NovelTypography.lineHeightRange)
        }
        if let width = defaults.object(forKey: columnWidthKey) as? Double {
            settings.columnWidth = width.clamped(to: NovelTypography.columnWidthRange)
        }
        if let spacing = defaults.object(forKey: paragraphSpacingKey) as? Double {
            settings.paragraphSpacing = spacing.clamped(to: NovelTypography.paragraphSpacingRange)
        }
        if let raw = defaults.string(forKey: familyKey), let family = NovelTypography.Family(rawValue: raw) {
            settings.family = family
        }
        if let raw = defaults.string(forKey: themeKey), let theme = NovelTypography.PageTheme(rawValue: raw) {
            settings.theme = theme
        }
        return settings
    }

    public static func setTypography(_ settings: NovelTypography, defaults: UserDefaults = .standard) {
        defaults.set(settings.fontSize, forKey: fontSizeKey)
        defaults.set(settings.lineHeight, forKey: lineHeightKey)
        defaults.set(settings.columnWidth, forKey: columnWidthKey)
        defaults.set(settings.paragraphSpacing, forKey: paragraphSpacingKey)
        defaults.set(settings.family.rawValue, forKey: familyKey)
        defaults.set(settings.theme.rawValue, forKey: themeKey)
    }

    /// The ncode inside a Syosetu URL: `n2267be` from both
    /// `ncode.syosetu.com/n2267be/` and `ncode.syosetu.com/n2267be/12/`.
    ///
    /// The chapter URL has to reduce to the same novel as the novel URL, or a
    /// reader who pastes a chapter link and one who pastes the table of
    /// contents would keep two separate sets of saved positions for the same
    /// book.
    public static func ncode(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        for component in url.pathComponents {
            let lowered = component.lowercased()
            guard lowered.hasPrefix("n") else { continue }
            let rest = lowered.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            let letters = rest.dropFirst(digits.count)
            // n + four or more digits + a one or two letter suffix. Syosetu
            // has never issued anything else, and the digits-then-letters
            // shape is what keeps a path segment like "novelview" out.
            if digits.count >= 4, (1...2).contains(letters.count), letters.allSatisfy(\.isLetter) {
                return lowered
            }
        }
        return nil
    }

    /// `anicat_novel_pos_<ncode>_<chapter>`.
    ///
    /// A URL with no ncode in it still gets a key — the reader accepts any
    /// pasted link and a mirror or a shortener would otherwise have every
    /// chapter share one position. Non-alphanumerics are folded to `_` so the
    /// fallback cannot collide with the `<ncode>_<chapter>` shape above it.
    public static func positionKey(sourceURL: String, chapter: Int) -> String {
        let book = ncode(from: sourceURL) ?? sanitized(sourceURL)
        return "\(positionKeyPrefix)_\(book)_\(chapter)"
    }

    private static func sanitized(_ raw: String) -> String {
        let folded = raw.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(folded)
    }

    public static func position(sourceURL: String, chapter: Int, defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: positionKey(sourceURL: sourceURL, chapter: chapter))
    }

    public static func setPosition(_ paragraph: Int, sourceURL: String, chapter: Int, defaults: UserDefaults = .standard) {
        defaults.set(paragraph, forKey: positionKey(sourceURL: sourceURL, chapter: chapter))
    }

    /// What the Novels page offers to continue.
    ///
    /// A novel read through the direct-URL reader has no AniList id — the
    /// catalog entry and the Syosetu ncode are not linked (see
    /// `AppModel.SyosetuSession`) — so this cannot hang off a card. It is
    /// stored on its own and shown next to the paste-a-link entry point,
    /// which is the only route back into the same book.
    public struct LastNovel: Equatable, Sendable {
        public let url: String
        public let title: String
        public let chapter: Int
        /// `"lnori"` or `"syosetu"`. Without it the resume button handed an
        /// lnori book URL to `novelInfo`, which refuses anything that is not
        /// a syosetu.com URL -- so "Continue chapter 4 of Volume 1" opened
        /// an error, with or without a network.
        public let source: String
        /// The AniList entry, for an lnori volume. Nil for a pasted Syosetu
        /// link, which has no catalogue entry behind it.
        public let catalogId: Int64?
    }

    public static func lastNovel(defaults: UserDefaults = .standard) -> LastNovel? {
        guard let url = defaults.string(forKey: lastNovelURLKey), !url.isEmpty else { return nil }
        let storedId = defaults.object(forKey: lastNovelCatalogIdKey) as? Int64
        return LastNovel(
            url: url,
            title: defaults.string(forKey: lastNovelTitleKey) ?? url,
            chapter: defaults.integer(forKey: lastNovelChapterKey),
            // A row written before the key existed is a Syosetu one: that was
            // the only source at the time.
            source: defaults.string(forKey: lastNovelSourceKey) ?? "syosetu",
            catalogId: storedId
        )
    }

    public static func setLastNovel(
        url: String,
        title: String,
        chapter: Int,
        source: String,
        catalogId: Int64?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(url, forKey: lastNovelURLKey)
        defaults.set(title, forKey: lastNovelTitleKey)
        defaults.set(chapter, forKey: lastNovelChapterKey)
        defaults.set(source, forKey: lastNovelSourceKey)
        if let catalogId {
            defaults.set(catalogId, forKey: lastNovelCatalogIdKey)
        } else {
            defaults.removeObject(forKey: lastNovelCatalogIdKey)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
