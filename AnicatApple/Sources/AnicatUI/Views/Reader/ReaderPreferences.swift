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
