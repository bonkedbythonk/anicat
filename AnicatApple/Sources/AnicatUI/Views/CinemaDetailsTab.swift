import SwiftUI
import AnicatCoreKit

/// The right-hand column of a cinema page's About tab: what TMDB knows
/// about a film or series that AniList has no field for.
///
/// It was a Details tab of its own, which made the cinema page's tabs a
/// different set from every other page's. A row is drawn only when there is
/// a value for it, so a title TMDB knows little about shows a short column
/// rather than a column of dashes.
struct CinemaDetailsTabSection: View {
    let extras: CinemaExtras
    let genres: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(facts, id: \.0) { label, value in
                    DetailFactRow(label: label) { Text(value) }
                }
            }

            if !extras.seasons.isEmpty {
                seasons
            }

            links
        }
    }

    // MARK: - Facts

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        if let date = extras.releaseDate, !date.isEmpty {
            rows.append((extras.lastAirDate == nil ? "Released" : "First aired", Self.date(date)))
        }
        if let last = extras.lastAirDate, !last.isEmpty {
            rows.append(("Last aired", Self.date(last)))
        }
        if let runtime = extras.runtimeMinutes, runtime > 0 {
            rows.append((extras.seasonCount == nil ? "Runtime" : "Episode length", Self.runtime(Int(runtime))))
        }
        if let seasons = extras.seasonCount {
            rows.append(("Seasons", "\(seasons)"))
        }
        if let episodes = extras.episodeCount {
            rows.append(("Episodes", "\(episodes)"))
        }
        if let language = extras.originalLanguage, !language.isEmpty {
            rows.append(("Original language", Self.language(language)))
        }
        if let budget = extras.budget {
            rows.append(("Budget", Self.money(budget)))
        }
        if let revenue = extras.revenue {
            rows.append(("Box office", Self.money(revenue)))
        }
        if !extras.companies.isEmpty {
            let label = extras.seasonCount == nil ? "Studios" : "Networks"
            rows.append((label, extras.companies.prefix(3).joined(separator: ", ")))
        }
        if !genres.isEmpty {
            rows.append(("Genres", genres.joined(separator: ", ")))
        }
        return rows
    }

    // MARK: - Seasons

    private var seasons: some View {
        VStack(alignment: .leading, spacing: 4) {
            SumiSectionHeader("Seasons", trailing: "\(extras.seasons.count)")

            // The same map the engine numbers episodes against, so what this
            // shows and what a play resolves cannot disagree: episode 11 of a
            // ten-episode first season is season 2 episode 1 in both places.
            ForEach(extras.seasons, id: \.number) { season in
                DetailFactRow(label: "Season \(season.number)") {
                    Text("\(season.episodeCount) episodes")
                }
            }
        }
    }

    /// Out to IMDb and the title's own site. A link and not a rating: IMDb
    /// publishes no free API, so the score above stays TMDB's.
    @ViewBuilder
    private var links: some View {
        let imdb = extras.imdbUrl.flatMap(URL.init(string:))
        let homepage = extras.homepage.flatMap(URL.init(string:))
        if imdb != nil || homepage != nil {
            HStack(spacing: 14) {
                if let imdb {
                    Link("View on IMDb", destination: imdb)
                }
                if let homepage {
                    Link("Official site", destination: homepage)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(SumiTheme.indigo)
        }
    }

    // MARK: - Formatting

    /// `1999-10-15` as `15 October 1999`. TMDB always answers in this shape,
    /// so a string that is not it is shown as it came rather than dropped.
    static func date(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let parsed = parser.date(from: raw) else { return raw }
        let out = DateFormatter()
        out.dateStyle = .long
        out.timeStyle = .none
        return out.string(from: parsed)
    }

    static func runtime(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Rounded rather than exact: TMDB's figures are gathered, not audited,
    /// and "$63.0M" claims about as much precision as they can carry.
    static func money(_ amount: Int64) -> String {
        let value = Double(amount)
        if value >= 1_000_000_000 {
            return String(format: "$%.2fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "$%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "$%.0fK", value / 1_000)
        }
        return "$\(amount)"
    }

    static func language(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

/// A film's or series' stills, left of the facts in About.
struct CinemaStillsShelf: View {
    let gallery: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SumiSectionHeader("Stills")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(gallery, id: \.self) { url in
                        CachedAsyncImage(url: URL(string: url)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            SumiTheme.card
                        }
                        .frame(width: 260, height: 146)
                        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            SumiRect(cornerRadius: SumiTheme.radiusSm).stroke(SumiTheme.border, lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .backSwipeExempt()
        }
    }
}
