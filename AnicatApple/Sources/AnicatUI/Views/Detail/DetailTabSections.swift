import SwiftUI
import AnicatCoreKit

/// The People tab: each character beside the voice actor who plays them.
struct CharactersTabSection: View {
    let titleId: Int64
    let characters: [MediaDetailView.CharacterItem]
    /// False on a TMDB page, whose list is actors with no voice cast.
    let tracksOnAniList: Bool
    let onSelectCharacter: (Int64) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        if characters.isEmpty {
            if AppModel.shared?.castSettledId == titleId {
                SumiEmptyState(headline: "No cast listed", detail: "AniList has no characters or staff for this title.")
            } else {
                SumiEmptyState(headline: "Cast and crew", detail: "Loading…")
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SumiSectionHeader(
                    tracksOnAniList ? "Cast and crew" : "Cast",
                    trailing: "\(characters.count) \(tracksOnAniList ? "characters" : "people")"
                )
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(characters) { character in
                        CharacterCastCard(character: character) {
                            onSelectCharacter(character.id)
                        }
                    }
                }
            }
        }
    }
}

/// A character on the left, their voice actor on the right.
private struct CharacterCastCard: View {
    let character: MediaDetailView.CharacterItem
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                face(character.imageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)
                    Text(MediaCard.displayRelation(character.role))
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let actor = character.voiceActorName, !actor.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(actor)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                        Text("Voice")
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                    }
                    face(character.voiceActorImageURL)
                }
            }
            .padding(8)
            .background(SumiTheme.card)
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusMd))
            .overlay(SumiRect(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
    }

    private func face(_ url: URL?) -> some View {
        Color.clear
            .frame(width: 40, height: 52)
            .overlay {
                CachedAsyncImage(url: url, maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.foregroundWash)
                }
            }
            .clipped()
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
    }
}

/// The Related tab: the watch order, then what AniList or TMDB recommend.
/// The franchise and the recommendations were two tabs, Related and More,
/// and the second was the one people found last.
struct RelatedTabSection: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let recommendations: [MediaDetailView.RecommendationItem]
    /// AniList only: a TMDB title has no franchise graph.
    let showsWatchOrder: Bool
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    private var hasWatchOrder: Bool {
        showsWatchOrder && (!relations.isEmpty || details.prequel != nil || details.sequel != nil)
    }

    var body: some View {
        if !hasWatchOrder && recommendations.isEmpty {
            SumiEmptyState(headline: "No related titles", detail: "No prequel, sequel, adaptation or recommendation is recorded for this title.")
        } else {
            VStack(alignment: .leading, spacing: 32) {
                if hasWatchOrder {
                    WatchOrderTimeline(
                        details: details,
                        relations: relations,
                        onSelectMediaId: onSelectMediaId
                    )
                }
                if !recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SumiSectionHeader(
                            "If you like this",
                            trailing: showsWatchOrder ? "From AniList recommendations" : "From TMDB"
                        )
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(recommendations) { rec in
                                    MediaDetailView.RecommendationCardView(rec: rec) {
                                        onSelectMediaId?(rec.id, rec.title, rec.coverURL, AppModel.isMangaFormat(rec.format))
                                    }
                                    .frame(width: 132)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        .backSwipeExempt()
                    }
                }
            }
        }
    }
}

/// The About tab: the synopsis, the trailer and the forum on the left, the
/// facts down the right. The synopsis sat in the header and the facts were
/// scattered between the meta line, a genre line and, on a film, a Details
/// tab of its own.
struct AboutTabSection: View {
    let details: HeroBanner.Details
    let isLoading: Bool
    let episodeRuntime: Int?
    let isMangaMedia: Bool
    let tracksOnAniList: Bool
    let hasTrailer: Bool
    let onOpenTrailer: () -> Void
    let discussions: [MediaDetailView.DiscussionItem]
    let onSelectThread: (Int64) -> Void
    /// Nil on an AniList page; see `MediaDetailView.cinemaExtras`.
    let cinemaExtras: CinemaExtras?

    @State private var isSynopsisExpanded = false
    @Environment(\.studioPageActions) private var studioPageActions

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                if let tagline = cinemaExtras?.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.system(size: 14, weight: .medium))
                        .italic()
                        .foregroundColor(SumiTheme.foreground.opacity(0.85))
                }
                synopsis
                if hasTrailer {
                    trailerCard
                }
                if let gallery = cinemaExtras?.gallery, !gallery.isEmpty {
                    CinemaStillsShelf(gallery: gallery)
                }
                if tracksOnAniList && !discussions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SumiSectionHeader("Discussion", trailing: "AniList forum")
                        ForEach(discussions) { thread in
                            MediaDetailView.DiscussionRowView(thread: thread) {
                                onSelectThread(thread.id)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Group {
                if let cinemaExtras {
                    CinemaDetailsTabSection(extras: cinemaExtras, genres: details.genres)
                } else {
                    aniListFacts
                }
            }
            .frame(width: 330, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var synopsis: some View {
        if let text = details.synopsis, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Body copy, not metadata: it reads at foreground/80 rather
                // than the muted token the labels around it use.
                Text(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                    .lineLimit(isSynopsisExpanded ? nil : 5)
                    .sumiTextSelectable()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                Button {
                    withAnimation(.snappy) { isSynopsisExpanded.toggle() }
                } label: {
                    Text(isSynopsisExpanded ? "Less" : "More")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(SumiTheme.indigo)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
        } else if isLoading {
            SynopsisSkeleton()
        } else {
            Text("No synopsis.")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
        }
    }

    /// The trailer's still with the word on it, white on a dark foot, opening
    /// the page's own trailer overlay.
    private var trailerCard: some View {
        Button(action: onOpenTrailer) {
            Color.clear
                .frame(width: 220, height: 124)
                .overlay {
                    CachedAsyncImage(url: details.trailerThumbnail.flatMap(URL.init(string:)), maxPixelSize: 440) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(SumiTheme.card)
                    }
                }
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .bottom, endPoint: .top)
                }
                .overlay {
                    HStack(spacing: 6) {
                        Image(anicat: "play.fill")
                            .font(.system(size: 11))
                        Text("Trailer")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.92))
                }
                .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
                .overlay(SumiRect(cornerRadius: SumiTheme.radiusSm).stroke(SumiTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    private var statusWord: String? {
        switch details.status {
        case "RELEASING": return isMangaMedia ? "Releasing" : "Airing"
        case "FINISHED": return "Finished"
        case "NOT_YET_RELEASED": return "Not out yet"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "On hiatus"
        default: return nil
        }
    }

    private var formatText: String? {
        guard let format = details.format else { return nil }
        let name = MediaCard.displayFormat(format)
        guard let runtime = episodeRuntime else { return name }
        return format == "MOVIE"
            ? "\(name), \(CinemaDetailsTabSection.runtime(runtime))"
            : "\(name), \(runtime) min episodes"
    }

    private var aniListFacts: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let formatText { DetailFactRow(label: "Format") { Text(formatText) } }
            if let statusWord { DetailFactRow(label: "Status") { Text(statusWord) } }
            if let year = details.year { DetailFactRow(label: "Year") { Text(String(year)) } }
            if let count = details.episodeCount, count > 0 {
                DetailFactRow(label: isMangaMedia ? "Chapters" : "Episodes") { Text("\(count)") }
            }
            studioFact
            if !details.genres.isEmpty {
                DetailFactRow(label: "Genres") { Text(details.genres.joined(separator: ", ")) }
            }
            if let romaji = details.romajiTitle, !romaji.isEmpty, romaji != details.title {
                DetailFactRow(label: "Also known as") { Text(romaji) }
            }
            if let score = details.averageScore, score > 0 {
                DetailFactRow(label: "Score") { Text(String(format: "%.1f average", Double(score) / 10)) }
            }
            if let mine = details.userScore, mine > 0 {
                DetailFactRow(label: "Your score") {
                    Text(mine.rounded() == mine ? String(Int(mine)) : String(format: "%.1f", mine))
                }
            }
        }
    }

    @ViewBuilder
    private var studioFact: some View {
        let studios = details.studios ?? []
        let main = studios.filter(\.isMain).isEmpty ? Array(studios.prefix(3)) : studios.filter(\.isMain)
        if !main.isEmpty {
            DetailFactRow(label: main.count == 1 ? "Studio" : "Studios") {
                HStack(spacing: 0) {
                    ForEach(Array(main.enumerated()), id: \.element.id) { index, studio in
                        if index > 0 { Text(", ") }
                        StudioButton(name: studio.name, idle: SumiTheme.indigo) {
                            studioPageActions.open(studio.id)
                        }
                    }
                }
            }
        } else if let studio = details.studio {
            DetailFactRow(label: "Studio") { Text(studio) }
        }
    }
}

/// One fact in About's right column: a muted label and its value, ruled.
struct DetailFactRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(SumiTheme.muted)
                .frame(width: 96, alignment: .leading)
            value()
                .foregroundColor(SumiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
    }
}
