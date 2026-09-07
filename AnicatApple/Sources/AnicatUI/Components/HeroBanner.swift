import SwiftUI

public struct HeroBanner: View {
    public struct Details: Sendable, Identifiable, Codable {
        public let id: Int64
        public let title: String
        public let romajiTitle: String?
        public let bannerURL: URL?
        public let coverURL: URL?
        public let format: String?
        public let year: Int?
        public let studio: String?
        public let synopsis: String?
        public let genres: [String]
        public let averageScore: Int?
        public let nextEpisodeText: String?
        /// AniList `status`: RELEASING, FINISHED, NOT_YET_RELEASED. Drives the
        /// one coloured word in the meta line.
        public let status: String?
        public let episodeCount: Int?
        /// Where the resume offer points, when there is one.
        public let resumeEpisode: Int?
        public let resumeSeconds: Int?
        public let prequel: Relation?
        public let sequel: Relation?
        /// `CURRENT`/`PLANNING`/`COMPLETED`/`DROPPED`/`PAUSED`/`REPEATING`, or
        /// `nil` when this title isn't on the signed-in user's list.
        public let listStatus: String?
        public let userScore: Double?
        /// The list entry's own id. `DeleteMediaListEntry` is keyed on this,
        /// not on `id` (the AniList media id).
        public let listEntryId: Int64?
        /// AniList's own progress count, separate from `resumeEpisode` (which
        /// comes from local watch history) — marking an episode watched by
        /// hand has to advance this one.
        public let listProgress: Int?
        public let isFavourite: Bool
        /// MyAnimeList's id for this same title, when AniList has the
        /// mapping. AniSkip (intro/outro skip times) is keyed by MAL id, not
        /// AniList's — this is the only bridge between the two catalogs.
        public let malId: Int64?
        /// `YOUTUBE` or `DAILYMOTION`. AniList stores no playable URL, so
        /// `TrailerPlayer` builds an embed URL from the pair.
        ///
        /// Optional, like every field added to this struct after the first
        /// `DetailCache` snapshots were written: a non-Optional property
        /// with a default value still goes through `decode` rather than
        /// `decodeIfPresent` in the synthesized initializer, so it would
        /// fail every cached file on disk instead of defaulting.
        public let trailerSite: String?
        public let trailerId: String?
        public let trailerThumbnail: String?
        /// Every credited studio, each with the id its own page is opened
        /// by. `studio` above stays as the single name the meta line has
        /// always drawn: it is the first name AniList returned, which is
        /// not reliably the animation studio.
        ///
        /// Optional for the reason `trailerSite` documents — a snapshot
        /// written before this field existed has no key for it.
        public let studios: [StudioRef]?

        /// A neighbouring season, as the detail page's chain cards draw it.
        public struct Relation: Sendable, Identifiable, Codable {
            public let id: Int64
            public let title: String
            public let format: String?
            public let coverURL: URL?

            public init(id: Int64, title: String, format: String? = nil, coverURL: URL? = nil) {
                self.id = id
                self.title = title
                self.format = format
                self.coverURL = coverURL
            }
        }

        /// One credited studio. `isMain` marks the animation studio rather
        /// than the rest of the production committee, which is the only
        /// thing that makes "Studio: MAPPA" narrower than a list of six
        /// licensing and music companies.
        public struct StudioRef: Sendable, Identifiable, Codable, Hashable {
            public let id: Int64
            public let name: String
            public let isMain: Bool

            public init(id: Int64, name: String, isMain: Bool) {
                self.id = id
                self.name = name
                self.isMain = isMain
            }
        }

        public init(
            id: Int64 = 0,
            title: String,
            romajiTitle: String? = nil,
            bannerURL: URL? = nil,
            coverURL: URL? = nil,
            format: String? = nil,
            year: Int? = nil,
            studio: String? = nil,
            synopsis: String? = nil,
            genres: [String] = [],
            averageScore: Int? = nil,
            nextEpisodeText: String? = nil,
            status: String? = nil,
            episodeCount: Int? = nil,
            resumeEpisode: Int? = nil,
            resumeSeconds: Int? = nil,
            prequel: Relation? = nil,
            sequel: Relation? = nil,
            listStatus: String? = nil,
            userScore: Double? = nil,
            listEntryId: Int64? = nil,
            listProgress: Int? = nil,
            isFavourite: Bool = false,
            malId: Int64? = nil,
            trailerSite: String? = nil,
            trailerId: String? = nil,
            trailerThumbnail: String? = nil,
            studios: [StudioRef]? = nil
        ) {
            self.trailerSite = trailerSite
            self.trailerId = trailerId
            self.trailerThumbnail = trailerThumbnail
            self.studios = studios
            self.status = status
            self.episodeCount = episodeCount
            self.resumeEpisode = resumeEpisode
            self.resumeSeconds = resumeSeconds
            self.prequel = prequel
            self.sequel = sequel
            self.listStatus = listStatus
            self.userScore = userScore
            self.listEntryId = listEntryId
            self.listProgress = listProgress
            self.isFavourite = isFavourite
            self.malId = malId
            self.id = id
            self.title = title
            self.romajiTitle = romajiTitle
            self.bannerURL = bannerURL
            self.coverURL = coverURL
            self.format = format
            self.year = year
            self.studio = studio
            self.synopsis = synopsis
            self.genres = genres
            self.averageScore = averageScore
            self.nextEpisodeText = nextEpisodeText
        }
    }

    public let details: Details
    public let onPrimaryAction: () -> Void
    public let onTrailerAction: (() -> Void)?

    public init(
        details: Details,
        onPrimaryAction: @escaping () -> Void,
        onTrailerAction: (() -> Void)? = nil
    ) {
        self.details = details
        self.onPrimaryAction = onPrimaryAction
        self.onTrailerAction = onTrailerAction
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop Image with Gradient Fade
            GeometryReader { geo in
                AsyncImage(url: details.bannerURL ?? details.coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    default:
                        Rectangle()
                            .fill(SumiTheme.card)
                    }
                }
                
                // Darkening Overlays for Sumi Ledger Contrast
                LinearGradient(
                    stops: [
                        .init(color: SumiTheme.background.opacity(0.1), location: 0.0),
                        .init(color: SumiTheme.background.opacity(0.75), location: 0.65),
                        .init(color: SumiTheme.background, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Left-to-right subtle vignette
                LinearGradient(
                    colors: [SumiTheme.background.opacity(0.85), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            // The `.animation(value: details.id)` below is scoped to this whole
            // ZStack, so without this the near-black placeholder Rectangle that
            // AsyncImage resets to on every title change would crossfade over
            // the previous banner image — a black bar smoothly fading in before
            // the new image pops in (untimed, since it lands outside this
            // transaction). Only the text content below should animate.
            .transaction { $0.animation = nil }

            // Content Overlay
            VStack(alignment: .leading, spacing: SumiTheme.spaceSm) {
                // Badges & Meta
                HStack(spacing: 8) {
                    if let format = details.format {
                        StatusBadge(.format(format))
                    }
                    if let year = details.year {
                        Text(String(year))
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                    }
                    if let studio = details.studio {
                        Text("• \(studio)")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                    }
                    if let score = details.averageScore, score > 0 {
                        StatusBadge(.score(score))
                    }
                }

                // Title
                Text(details.title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.7)
                    .lineSpacing(2)
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(2)

                if let romaji = details.romajiTitle, romaji != details.title {
                    Text(romaji)
                        .font(.system(size: 14))
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }

                // Synopsis
                if let synopsis = details.synopsis {
                    Text(synopsis)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(3)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(3)
                        .padding(.top, 2)
                        .frame(maxWidth: 600, alignment: .leading)
                }

                // Actions
                HStack(spacing: 12) {
                    Button(action: onPrimaryAction) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                            Text(details.nextEpisodeText ?? "Watch Now")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(SumiTheme.background)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SumiTheme.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)

                    if let onTrailer = onTrailerAction {
                        Button(action: onTrailer) {
                            HStack(spacing: 6) {
                                Image(systemName: "film")
                                    .font(.system(size: 13))
                                Text("Trailer")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(SumiTheme.foreground)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(SumiTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
                            .overlay(
                                RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                                    .stroke(SumiTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
                .padding(.top, 8)
            }
            .padding(SumiTheme.spaceLg)
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .animation(.smooth, value: details.id)
    }
}
