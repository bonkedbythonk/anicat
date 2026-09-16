#if os(iOS)
import SwiftUI
import AnicatCoreKit

/// The Mac's seven search dropdowns, as one value.
///
/// Empty string means "any" throughout, matching what `SearchView` stores
/// and what the engine treats as unset; the value is `Equatable` so the
/// search tab can watch it with one `onChange` rather than seven.
struct PhoneSearchFilters: Equatable {
    var mediaType = "ANIME"
    var genre = ""
    var year = ""
    var season = ""
    var format = ""
    var minScore = ""
    var status = ""
    var sort = ""

    enum Key: CaseIterable { case genre, year, season, format, minScore, status, sort }

    var isActive: Bool { !activeChips.isEmpty }

    var placeholder: String {
        switch mediaType {
        case "MANGA": return "Search manga"
        case "NOVEL": return "Search light novels"
        default: return "Search anime"
        }
    }

    /// A season without a year is meaningless to AniList, and a format
    /// from the anime list means nothing on a manga search; both are
    /// dropped here rather than sent, the same rule `SearchView` applies.
    var engineFilters: SearchFilters {
        SearchFilters(
            genre: genre.isEmpty ? nil : genre,
            year: Int32(year),
            season: (season.isEmpty || year.isEmpty || mediaType != "ANIME") ? nil : season,
            format: effectiveFormat.isEmpty ? nil : effectiveFormat,
            minScore: Int32(minScore),
            status: status.isEmpty ? nil : status,
            sort: sort.isEmpty ? nil : sort
        )
    }

    var effectiveFormat: String {
        guard let options = formatOptions, options.contains(where: { $0.value == format }) else { return "" }
        return format
    }

    var formatOptions: [(value: String, label: String)]? {
        switch mediaType {
        case "NOVEL": return nil
        case "MANGA": return Self.mangaFormatOptions
        default: return Self.animeFormatOptions
        }
    }

    struct Chip { let key: Key; let label: String }

    var activeChips: [Chip] {
        var chips: [Chip] = []
        if !genre.isEmpty { chips.append(Chip(key: .genre, label: genre)) }
        if !year.isEmpty { chips.append(Chip(key: .year, label: year)) }
        if !season.isEmpty, !year.isEmpty, mediaType == "ANIME" {
            chips.append(Chip(key: .season, label: Self.label(season, in: Self.seasonOptions)))
        }
        if !effectiveFormat.isEmpty, let options = formatOptions {
            chips.append(Chip(key: .format, label: Self.label(effectiveFormat, in: options)))
        }
        if !minScore.isEmpty { chips.append(Chip(key: .minScore, label: Self.label(minScore, in: Self.scoreOptions))) }
        if !status.isEmpty { chips.append(Chip(key: .status, label: Self.label(status, in: Self.statusOptions))) }
        if !sort.isEmpty { chips.append(Chip(key: .sort, label: Self.label(sort, in: Self.sortOptions))) }
        return chips
    }

    mutating func clear(_ key: Key) {
        switch key {
        case .genre: genre = ""
        case .year: year = ""
        case .season: season = ""
        case .format: format = ""
        case .minScore: minScore = ""
        case .status: status = ""
        case .sort: sort = ""
        }
    }

    mutating func clearAll() {
        for key in Key.allCases { clear(key) }
    }

    static func label(_ value: String, in options: [(value: String, label: String)]) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    // The same lists `SearchView` carries; kept in step by hand.
    static let genreOptions: [(value: String, label: String)] = [
        ("", "Any"), ("Action", "Action"), ("Adventure", "Adventure"), ("Comedy", "Comedy"),
        ("Drama", "Drama"), ("Ecchi", "Ecchi"), ("Fantasy", "Fantasy"), ("Horror", "Horror"),
        ("Mahou Shoujo", "Mahou Shoujo"), ("Mecha", "Mecha"), ("Music", "Music"), ("Mystery", "Mystery"),
        ("Psychological", "Psychological"), ("Romance", "Romance"), ("Sci-Fi", "Sci-Fi"),
        ("Slice of Life", "Slice of Life"), ("Sports", "Sports"), ("Supernatural", "Supernatural"),
        ("Thriller", "Thriller")
    ]
    static var yearOptions: [(value: String, label: String)] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return [("", "Any")] + (1970...(currentYear + 1)).reversed().map { (String($0), String($0)) }
    }
    static let seasonOptions: [(value: String, label: String)] = [
        ("", "Any"), ("WINTER", "Winter"), ("SPRING", "Spring"), ("SUMMER", "Summer"), ("FALL", "Fall")
    ]
    static let animeFormatOptions: [(value: String, label: String)] = [
        ("", "Any"), ("TV", "TV"), ("TV_SHORT", "TV Short"), ("MOVIE", "Movie"),
        ("SPECIAL", "Special"), ("OVA", "OVA"), ("ONA", "ONA"), ("MUSIC", "Music")
    ]
    static let mangaFormatOptions: [(value: String, label: String)] = [
        ("", "Any"), ("MANGA", "Manga"), ("NOVEL", "Novel"), ("ONE_SHOT", "One Shot")
    ]
    static let scoreOptions: [(value: String, label: String)] = [
        ("", "Any"), ("90", "90+"), ("80", "80+"), ("70", "70+"), ("60", "60+"), ("50", "50+")
    ]
    static let statusOptions: [(value: String, label: String)] = [
        ("", "Any"), ("RELEASING", "Releasing"), ("FINISHED", "Finished"),
        ("NOT_YET_RELEASED", "Not Yet Released"), ("HIATUS", "Hiatus"), ("CANCELLED", "Cancelled")
    ]
    static let sortOptions: [(value: String, label: String)] = [
        ("", "Popularity"), ("SCORE_DESC", "Score"), ("TRENDING_DESC", "Trending"),
        ("START_DATE_DESC", "Newest"), ("TITLE_ROMAJI", "Title A-Z")
    ]
}

/// The filter sheet. A `Form` of pickers rather than seven inline menus:
/// the Mac wraps its dropdowns into two rows above the results, which on
/// 402pt would be four rows before the first poster.
struct PhoneSearchFilterSheet: View {
    @Binding var filters: PhoneSearchFilters
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $filters.mediaType) {
                        Text("Anime").tag("ANIME")
                        Text("Manga").tag("MANGA")
                        Text("Light novels").tag("NOVEL")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    picker("Genre", $filters.genre, PhoneSearchFilters.genreOptions)
                    picker("Year", $filters.year, PhoneSearchFilters.yearOptions)
                    if filters.mediaType == "ANIME" {
                        picker("Season", $filters.season, PhoneSearchFilters.seasonOptions)
                            .disabled(filters.year.isEmpty)
                        if filters.year.isEmpty {
                            Text("Pick a year to filter by season.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(SumiTheme.muted)
                        }
                    }
                    if let formats = filters.formatOptions {
                        picker("Format", $filters.format, formats)
                    }
                    picker("Score", $filters.minScore, PhoneSearchFilters.scoreOptions)
                    picker("Status", $filters.status, PhoneSearchFilters.statusOptions)
                }
                Section {
                    picker("Sort", $filters.sort, PhoneSearchFilters.sortOptions)
                }
                if filters.isActive {
                    Section {
                        Button("Clear filters", role: .destructive) { filters.clearAll() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SumiTheme.background)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func picker(_ title: String, _ selection: Binding<String>, _ options: [(value: String, label: String)]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
    }
}
#endif
