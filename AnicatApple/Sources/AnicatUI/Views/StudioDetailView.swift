import SwiftUI
import AnicatCoreKit

/// The AniList studio page, in the app. Reached from the studio buttons in
/// the detail page's meta line, and from the "More from" shelf's heading.
struct StudioDetailView: View {
    let studio: FfiStudioDetail
    /// catalog id, title, cover URL string, format — everything
    /// `openDetail` needs, without this view knowing about `AppModel`.
    let onOpenTitle: (Int64, String, String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            if !studio.media.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PersonSectionLabel("Works", trailing: "\(studio.media.count)")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        // Indexed rather than keyed on `catalogId`: a studio
                        // credited twice for one title (a season and its
                        // recap, say) comes back as two rows with the same
                        // id, and a duplicate `ForEach` id drops one of them.
                        ForEach(Array(studio.media.enumerated()), id: \.offset) { _, work in
                            PersonMediaPoster(
                                title: work.title,
                                coverImage: work.coverImage,
                                // `MediaSummary` carries no year, so the
                                // caption is the format alone — the engine
                                // already returns these newest first, which
                                // is the ordering the year would have given.
                                year: nil,
                                caption: work.format
                            ) {
                                onOpenTitle(work.catalogId, work.title, work.coverImage, work.format)
                            }
                        }
                    }
                }
            } else {
                SumiEmptyState(
                    headline: "No Works Listed",
                    detail: "AniList has no titles credited to this studio."
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(studio.name)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.5)
                .foregroundColor(SumiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if studio.isAnimationStudio {
                    StatusBadge(.format("Animation Studio"))
                }
                if studio.favourites > 0 {
                    StatusBadge(.neutral("\(studio.favourites) favourites"))
                }
            }
        }
    }
}
