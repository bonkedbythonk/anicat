import SwiftUI
import AnicatCoreKit

/// The AniList staff page, in the app. Reached from a character page's
/// voice-actor chips, and from any other staff link added later.
struct StaffDetailView: View {
    let staff: FfiStaffDetail
    let onOpenCharacter: (Int64) -> Void
    /// catalog id, title, cover URL string, media type, format — everything
    /// `openDetail` needs, without this view knowing about `AppModel`.
    let onOpenTitle: (Int64, String, String, String?, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            if staff.description?.isEmpty == false {
                AniListMarkdownText(staff.description)
            }

            if !staff.characterCredits.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PersonSectionLabel("Characters", trailing: "\(staff.characterCredits.count)")
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(staff.characterCredits.enumerated()), id: \.offset) { _, credit in
                            StaffCharacterCreditRow(
                                credit: credit,
                                onOpenCharacter: onOpenCharacter,
                                onOpenTitle: {
                                    onOpenTitle(
                                        credit.catalogId,
                                        credit.title,
                                        credit.coverImage,
                                        credit.mediaType,
                                        credit.format
                                    )
                                }
                            )
                        }
                    }
                }
            }

            if !staff.mediaCredits.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    PersonSectionLabel("Works", trailing: "\(staff.mediaCredits.count)")
                    ForEach(groupedWorks, id: \.role) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.role)
                                .sumiTabularMono(size: 10.5, weight: .medium)
                                .foregroundColor(SumiTheme.foreground.opacity(0.7))
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16, alignment: .top)],
                                alignment: .leading,
                                spacing: 18
                            ) {
                                ForEach(Array(group.credits.enumerated()), id: \.offset) { _, credit in
                                    PersonMediaPoster(
                                        title: credit.title,
                                        coverImage: credit.coverImage,
                                        year: credit.year,
                                        caption: credit.format
                                    ) {
                                        onOpenTitle(
                                            credit.catalogId,
                                            credit.title,
                                            credit.coverImage,
                                            credit.mediaType,
                                            credit.format
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            PersonPortrait(imageURL: staff.imageUrl)

            VStack(alignment: .leading, spacing: 10) {
                Text(staff.name)
                    .font(.sumiHeading(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundColor(SumiTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let native = staff.nativeName, !native.isEmpty {
                    Text(native)
                        .font(.system(size: 15))
                        .foregroundColor(SumiTheme.muted)
                }

                if !staff.primaryOccupations.isEmpty {
                    Text(staff.primaryOccupations.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    ForEach(metaBadges, id: \.self) { badge in
                        StatusBadge(.neutral(badge))
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var metaBadges: [String] {
        var badges: [String] = []
        if let language = staff.language, !language.isEmpty { badges.append(language) }
        if let home = staff.homeTown, !home.isEmpty { badges.append(home) }
        if staff.favourites > 0 { badges.append("\(staff.favourites) favourites") }
        return badges
    }

    struct WorkGroup {
        let role: String
        let credits: [FfiStaffMediaCredit]
    }

    /// Grouped in first-appearance order rather than alphabetically:
    /// AniList returns credits by the show's popularity, so the first role
    /// to appear is the one this person is known for, and sorting by name
    /// would bury "Director" under "Key Animation".
    var groupedWorks: [WorkGroup] {
        var order: [String] = []
        var buckets: [String: [FfiStaffMediaCredit]] = [:]
        for credit in staff.mediaCredits {
            let role = credit.staffRole?.isEmpty == false ? credit.staffRole! : "Other"
            if buckets[role] == nil {
                buckets[role] = []
                order.append(role)
            }
            buckets[role]?.append(credit)
        }
        return order.map { WorkGroup(role: $0, credits: buckets[$0] ?? []) }
    }
}

private struct StaffCharacterCreditRow: View {
    let credit: FfiStaffCharacterCredit
    let onOpenCharacter: (Int64) -> Void
    let onOpenTitle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpenTitle) {
                HStack(alignment: .top, spacing: 10) {
                    CachedAsyncImage(url: URL(string: credit.coverImage), maxPixelSize: 200) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(SumiTheme.card)
                    }
                    .frame(width: 52, height: 78)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(credit.title)
                            .font(.sumiHeading(size: 13, weight: .semibold))
                            .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            if let year = credit.year {
                                Text(String(year))
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                            if let role = credit.characterRole {
                                Text(CharacterDetailView.humanized(role))
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted.opacity(0.8))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 220, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 8, alignment: .top)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(credit.characters.enumerated()), id: \.offset) { _, character in
                    PersonAvatarChip(
                        name: character.name,
                        imageURL: character.imageUrl,
                        caption: nil
                    ) {
                        onOpenCharacter(character.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(SumiTheme.foreground.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border.opacity(0.5), lineWidth: 1)
        )
    }
}
