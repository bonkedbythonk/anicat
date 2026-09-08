import SwiftUI
import AnicatCoreKit

/// The Details tab of a cinema page: what TMDB knows about a film or series
/// that AniList has no field for.
///
/// It exists because the anime page's own tabs go thin on a film -- no
/// relations graph, no forum threads, no per-episode list worth a tab -- and
/// what replaces them is real: the box office, the studios or networks, the
/// season breakdown, the stills. A row is drawn only when there is a value
/// for it, so a title TMDB knows little about shows a short panel rather than
/// a column of dashes.
struct CinemaDetailsTabSection: View {
    let extras: CinemaExtras
    let genres: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let tagline = extras.tagline {
                Text(tagline)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(SumiTheme.foreground.opacity(0.85))
            }

            factsGrid

            if !extras.seasons.isEmpty {
                seasons
            }

            if !extras.gallery.isEmpty {
                stills
            }

            links
        }
        .padding(.vertical, 4)
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

    private var factsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 16, alignment: .leading)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(facts, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased())
                        .sumiTabularMono(size: 9.5, weight: .bold)
                        .foregroundColor(SumiTheme.muted)
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Seasons

    private var seasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEASONS")
                .sumiTabularMono(size: 9.5, weight: .bold)
                .foregroundColor(SumiTheme.muted)

            // The same map the engine numbers episodes against, so what this
            // shows and what a play resolves cannot disagree: episode 11 of a
            // ten-episode first season is season 2 episode 1 in both places.
            ForEach(extras.seasons, id: \.number) { season in
                HStack(spacing: 10) {
                    Text("Season \(season.number)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                    Spacer()
                    Text("\(season.episodeCount) episodes")
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(SumiTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(SumiTheme.border, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Stills

    private var stills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STILLS")
                .sumiTabularMono(size: 9.5, weight: .bold)
                .foregroundColor(SumiTheme.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(extras.gallery, id: \.self) { url in
                        CachedAsyncImage(url: URL(string: url)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            SumiTheme.card
                        }
                        .frame(width: 260, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .sumiShelfEdge()
                    }
                }
                .padding(.vertical, 2)
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
