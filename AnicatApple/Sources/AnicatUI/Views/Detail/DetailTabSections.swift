import SwiftUI
import AnicatCoreKit

struct CharactersTabSection: View {
    let titleId: Int64
    let characters: [MediaDetailView.CharacterItem]
    let onSelectCharacter: (Int64) -> Void

    var body: some View {
        if characters.isEmpty {
            if AppModel.shared?.castSettledId == titleId {
                SumiEmptyState(headline: "No cast listed", detail: "AniList has no characters or staff for this title.")
            } else {
                SumiEmptyState(headline: "Cast and staff", detail: "Loading…")
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], spacing: 14) {
                ForEach(characters) { char in
                    Button {
                        onSelectCharacter(char.id)
                    } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .aspectRatio(2/3, contentMode: .fit)
                            .overlay {
                                CachedAsyncImage(url: char.imageURL, maxPixelSize: 320) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(SumiTheme.card)
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(char.name)
                                .font(.sumiHeading(size: 12, weight: .bold))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            // The role in the line under the name, not a black
                            // badge stamped on the portrait.
                            Text([MediaCard.displayRelation(char.role), char.voiceActorName]
                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundColor(SumiTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    }
                    .buttonStyle(.sumiPressable)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

struct RelatedTabSection: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let prequel: HeroBanner.Details.Relation?
    let sequel: HeroBanner.Details.Relation?
    let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    @State private var mode = "grid"

    private static let mainTypes: Set<String> = ["PREQUEL", "SEQUEL", "ADAPTATION", "PARENT", "SOURCE"]

    var body: some View {
        if relations.isEmpty && prequel == nil && sequel == nil {
            SumiEmptyState(headline: "No related titles", detail: "No prequel, sequel, manga, light novel, or related adaptations recorded.")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                SumiSegmentedControl(
                    options: [("grid", "Grid"), ("timeline", "Timeline")],
                    selection: $mode
                )
                .fixedSize()

                if mode == "timeline" {
                    WatchOrderTimeline(
                        details: details,
                        relations: relations,
                        onSelectMediaId: onSelectMediaId
                    )
                } else {
                    grid
                }
            }
        }
    }

    private var grid: some View {
        Group {
            VStack(alignment: .leading, spacing: 20) {
                let mainRels = relations.filter { Self.mainTypes.contains($0.relationType) }
                let otherRels = relations.filter { !Self.mainTypes.contains($0.relationType) }

                if !mainRels.isEmpty || prequel != nil || sequel != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Seasons & adaptations")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.indigo)

                        if !mainRels.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)], spacing: 12) {
                                ForEach(mainRels) { rel in
                                    MediaDetailView.RelatedMediaCard(relation: rel) {
                                        let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                        onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                    }
                                }
                            }
                        } else if prequel != nil || sequel != nil {
                            HStack(spacing: 12) {
                                if let prequel {
                                    MediaDetailView.RelationCardView(relation: prequel, label: "Previous season", leading: true, onSelect: onSelectRelation)
                                }
                                if let sequel {
                                    MediaDetailView.RelationCardView(relation: sequel, label: "Next season", leading: false, onSelect: onSelectRelation)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if !otherRels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Other relations")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)], spacing: 12) {
                            ForEach(otherRels) { rel in
                                MediaDetailView.RelatedMediaCard(relation: rel) {
                                    let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                    onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DiscussionsTabSection: View {
    let discussions: [MediaDetailView.DiscussionItem]
    let onSelectThread: (Int64) -> Void

    var body: some View {
        if discussions.isEmpty {
            SumiEmptyState(headline: "No discussions", detail: "No community discussion threads found for this title.")
        } else {
            VStack(spacing: 8) {
                ForEach(discussions) { thread in
                    MediaDetailView.DiscussionRowView(thread: thread) {
                        onSelectThread(thread.id)
                    }
                }
            }
        }
    }
}

struct RecommendationsTabSection: View {
    let recommendations: [MediaDetailView.RecommendationItem]
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    var body: some View {
        if recommendations.isEmpty {
            SumiEmptyState(headline: "No recommendations", detail: "No community recommendations found.")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recommendations")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.indigo)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 165), spacing: 14)], spacing: 14) {
                    ForEach(recommendations) { rec in
                        MediaDetailView.RecommendationCardView(rec: rec) {
                            let isManga = rec.format == "MANGA" || rec.format == "NOVEL" || rec.format == "ONE_SHOT"
                            onSelectMediaId?(rec.id, rec.title, rec.coverURL, isManga)
                        }
                    }
                }
            }
        }
    }
}
