import SwiftUI
import AnicatCoreKit

/// The Related tab's Timeline: the title and everything around it in the
/// order someone would watch them, grouped by year.
///
/// Built from the engine's franchise walk (`AppModel.franchise`), which
/// follows the prequel/sequel line to both ends with start dates. The
/// title's own relations are one step deep -- from Sword Art Online they
/// reached SAO II and stopped short of Alicization -- so they are only the
/// fallback when the walk fails, with years from whatever detail snapshots
/// are on disk (`DetailCache.peekFacts`).
struct WatchOrderTimeline: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    @State private var groups: [WatchOrder.YearGroup] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.label)
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.indigo)

                    VStack(spacing: 6) {
                        ForEach(group.entries) { entry in
                            WatchOrderRow(entry: entry) {
                                guard !entry.isCurrent else { return }
                                onSelectMediaId?(
                                    entry.id,
                                    entry.title,
                                    entry.coverURL,
                                    AppModel.isMangaFormat(entry.format)
                                )
                            }
                        }
                    }
                }
            }
        }
        // Reading a snapshot per relation is file I/O, so it stays off the
        // body and out of the main actor's way; the timeline draws empty
        // for the frame it takes.
        //
        // Keyed on the relation count as well as the title: the page
        // renders from a cached snapshot first and the fresh fetch fills
        // `relations` afterwards. On the id alone the Grid picked those up
        // (it reads the array in its own body) and the timeline kept
        // showing the current title by itself.
        .task(id: "\(details.id)-\(relations.count)") {
            if details.mediaCatalog == .anilist,
               let franchise = await AppModel.shared?.franchise(id: details.id),
               let entries = Self.entries(details: details, franchise: franchise) {
                groups = WatchOrder.grouped(entries)
                return
            }
            let entries = await Self.entries(details: details, relations: relations)
            groups = WatchOrder.grouped(entries)
        }
    }

    /// The walk's entries in watch order. The main line carries no relation
    /// type of its own, so each entry is placed before or after the open
    /// title by start date, which is what `WatchOrder.sort` ranks on. Nil if
    /// the walk did not include the open title, which would leave the rail
    /// with no "you are here".
    private static func entries(
        details: HeroBanner.Details,
        franchise: [FfiFranchiseEntry]
    ) -> [WatchOrder.Entry]? {
        guard let here = franchise.first(where: { $0.catalogId == details.id }) else { return nil }
        func started(_ entry: FfiFranchiseEntry) -> Int? {
            entry.year.map { Int($0) * 12 + Int(entry.month ?? 0) }
        }
        let hereStarted = started(here)
        let current = WatchOrder.Entry(
            id: details.id,
            title: details.title,
            relationType: nil,
            format: details.format,
            coverURL: details.coverURL,
            year: here.year.map(Int.init) ?? details.year,
            season: here.season,
            episodeCount: details.episodeCount,
            listStatus: details.listStatus,
            isCurrent: true
        )
        let others = franchise.filter { $0.catalogId != details.id }.map { entry -> WatchOrder.Entry in
            let placed: String
            if let aside = entry.aside {
                placed = aside
            } else if let start = started(entry), let hereStart = hereStarted, start < hereStart {
                placed = "PREQUEL"
            } else {
                placed = "SEQUEL"
            }
            return WatchOrder.Entry(
                id: entry.catalogId,
                title: entry.title,
                relationType: placed,
                format: entry.format,
                coverURL: URL(string: entry.coverImage),
                year: entry.year.map(Int.init),
                season: entry.season,
                episodeCount: entry.episodes.map(Int.init),
                listStatus: entry.listStatus
            )
        }
        return WatchOrder.sort(relations: others, current: current)
    }

    private static func entries(
        details: HeroBanner.Details,
        relations: [MediaDetailView.RelationItem]
    ) async -> [WatchOrder.Entry] {
        await Task.detached(priority: .userInitiated) {
            let current = WatchOrder.Entry(
                id: details.id,
                title: details.title,
                relationType: nil,
                format: details.format,
                coverURL: details.coverURL,
                year: details.year,
                episodeCount: details.episodeCount,
                listStatus: details.listStatus,
                isCurrent: true
            )
            let mapped = relations.map { relation -> WatchOrder.Entry in
                let isManga = AppModel.isMangaFormat(relation.format)
                // A title can be cached under either kind — the detail
                // loader falls back to the opposite one when AniList
                // disagrees with the format — so a miss is retried the
                // other way round before giving up.
                let facts = DetailCache.peekFacts(id: relation.id, isManga: isManga)
                    ?? DetailCache.peekFacts(id: relation.id, isManga: !isManga)
                return WatchOrder.Entry(
                    id: relation.id,
                    title: relation.title,
                    relationType: relation.relationType,
                    format: relation.format,
                    coverURL: relation.coverURL,
                    year: facts?.year,
                    episodeCount: facts?.episodeCount,
                    listStatus: facts?.listStatus
                )
            }
            return WatchOrder.sort(relations: mapped, current: current)
        }.value
    }
}

/// One title on the timeline. The viewed title keeps its left rail so the
/// eye finds "you are here" without reading a single row label.
struct WatchOrderRow: View {
    let entry: WatchOrder.Entry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(entry.isCurrent ? SumiTheme.indigo : Color.clear)
                    .frame(width: 2)

                Color.clear
                    .frame(width: 34, height: 48)
                    .overlay {
                        CachedAsyncImage(url: entry.coverURL, maxPixelSize: 120) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: entry.isCurrent ? .bold : .semibold))
                        .foregroundColor(isHovered && !entry.isCurrent ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(badgeLabel)
                            .sumiTabularMono(size: 9.5)
                            .foregroundColor(entry.isCurrent ? SumiTheme.indigo : SumiTheme.muted)
                        if let format = entry.format {
                            Text(MediaCard.displayFormat(format))
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                        }
                        if let count = entry.episodeCount, count > 0 {
                            Text("\(count) ep")
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                        }
                        if let status = entry.listStatus {
                            Text(MediaCard.displayRelation(status))
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.indigo.opacity(0.8))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(isHovered && !entry.isCurrent ? SumiTheme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(entry.isCurrent)
        .stableHover { isHovered = $0 }
        .animation(.sumi(.pop), value: isHovered)
    }

    private var badgeLabel: String {
        if entry.isCurrent { return "You are here" }
        guard let type = entry.relationType else { return "Related" }
        return MediaCard.displayRelation(type)
    }
}
