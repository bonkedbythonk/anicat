#if os(macOS)
import SwiftUI

struct ReadingTabSection: View {
    // The global halves of `ReaderPreferences`' per-title keys: what a title
    // never opened before starts from. The reader writes the direction one
    // too, never the layout one. Literals and defaults must agree with
    // `ReaderPreferences.mode` (webtoon) and `isRightToLeft` (true).
    @AppStorage("anicat_reader_mode") private var readerMode: String = MangaReaderView.ReadingMode.webtoon.rawValue
    @AppStorage("anicat_reader_rtl") private var readerRTL: Bool = true
    // `AnicatEngine.japaneseMangaKey`, spelled out because `@AppStorage`
    // needs a literal.
    @AppStorage("anicat_manga_japanese") private var japaneseManga: Bool = false
    // `NovelPreferences.typography` is the reader and `NovelTypography`
    // holds the defaults (serif, 17pt); the literals here must agree.
    @AppStorage("anicat_novel_family") private var novelFamily: String = NovelTypography.Family.serif.rawValue
    @AppStorage("anicat_novel_font_size") private var novelFontSize: Double = 17
    // Same literal-key constraint. `AppModel.isLnoriEnabled` owns the reader
    // and the default (off).
    @AppStorage("anicat_lnori_enabled") private var lnoriEnabled: Bool = false

    private static let fontSizes = Array(Int(NovelTypography.fontSizeRange.lowerBound)...Int(NovelTypography.fontSizeRange.upperBound)).map(String.init)

    var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "Manga") {
            SettingField(
                label: "Layout for new titles",
                description: "Each title remembers its own after you change it"
            ) {
                SumiSlashToggle(
                    MangaReaderView.ReadingMode.allCases.map { ($0.rawValue, $0.label) },
                    selection: readerMode
                ) { readerMode = $0 }
            }

            SettingField(label: "Direction", description: "For paged layouts; also remembered per title") {
                SumiSlashToggle([(true, "Right to left"), (false, "Left to right")], selection: readerRTL) { readerRTL = $0 }
            }

            SettingField(
                label: "Chapter language",
                description: "Japanese reads untranslated chapters from Sen Manga, a smaller catalogue"
            ) {
                SumiSlashToggle([(false, "English"), (true, "日本語")], selection: japaneseManga) { japaneseManga = $0 }
            }
        }

        SettingsCard(title: "Light novels") {
            SettingField(label: "Face") {
                SumiSlashToggle(
                    NovelTypography.Family.allCases.map { ($0.rawValue, $0.label) },
                    selection: novelFamily
                ) { novelFamily = $0 }
            }

            SettingField(label: "Size") {
                SumiDropdown(options: Self.fontSizes, selected: Binding(
                    get: { String(Int(novelFontSize.rounded())) },
                    set: { if let size = Double($0) { novelFontSize = size } }
                ))
            }

            // Opt-in rather than a source picker: Syosetu carries text its
            // authors publish for free, Lnori carries publisher-owned
            // volumes, and the app must not contact the second unasked.
            SettingField(
                label: "Official volumes",
                description: "From a third-party site that hosts licensed light novels; Syosetu is unaffected"
            ) {
                SumiSwitch(isOn: $lnoriEnabled, label: "Official volumes")
            }
        }
    }
    }
}
#endif
