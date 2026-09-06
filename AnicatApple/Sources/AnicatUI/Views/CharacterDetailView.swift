import SwiftUI
import AnicatCoreKit

/// The AniList character page, in the app. Replaces the
/// `openExternal("https://anilist.co/character/<id>")` the Cast & Staff grid
/// used to do.
struct CharacterDetailView: View {
    let character: FfiCharacterDetail
    let onOpenStaff: (Int64) -> Void
    let onOpenTitle: (FfiCharacterAppearance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            if character.description?.isEmpty == false {
                AniListMarkdownText(character.description)
            }

            if !voiceActors.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PersonSectionLabel("Voice actors", trailing: "\(voiceActors.count)")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(voiceActors, id: \.id) { actor in
                            PersonAvatarChip(
                                name: actor.name,
                                imageURL: actor.imageUrl,
                                caption: actor.language
                            ) {
                                onOpenStaff(actor.id)
                            }
                        }
                    }
                }
            }

            if !character.appearances.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PersonSectionLabel("Appearances", trailing: "\(character.appearances.count)")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(Array(character.appearances.enumerated()), id: \.offset) { _, appearance in
                            PersonMediaPoster(
                                title: appearance.title,
                                coverImage: appearance.coverImage,
                                year: appearance.year,
                                caption: appearance.characterRole.map(Self.humanized)
                            ) {
                                onOpenTitle(appearance)
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            PersonPortrait(imageURL: character.imageUrl)

            VStack(alignment: .leading, spacing: 10) {
                Text(character.name)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundColor(SumiTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let native = character.nativeName, !native.isEmpty {
                    Text(native)
                        .font(.system(size: 15))
                        .foregroundColor(SumiTheme.muted)
                }

                if !character.alternativeNames.isEmpty {
                    Text(character.alternativeNames.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted.opacity(0.8))
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
        if let gender = character.gender, !gender.isEmpty { badges.append(gender) }
        if let age = character.age, !age.isEmpty { badges.append("Age \(age)") }
        if let birthday = Self.birthday(
            year: character.birthYear,
            month: character.birthMonth,
            day: character.birthDay
        ) {
            badges.append(birthday)
        }
        if character.favourites > 0 {
            badges.append("\(character.favourites) favourites")
        }
        return badges
    }

    /// AniList birthdays routinely carry a month and day and no year, so
    /// each combination is spelled out rather than fed through one date
    /// format that would invent a missing component.
    static func birthday(year: Int32?, month: Int32?, day: Int32?) -> String? {
        let symbols = Calendar.current.monthSymbols
        let monthName: String? = month.flatMap { value in
            let index = Int(value) - 1
            return symbols.indices.contains(index) ? symbols[index] : nil
        }
        switch (monthName, day, year) {
        case let (name?, day?, year?): return "\(name) \(day), \(year)"
        case let (name?, day?, nil): return "\(name) \(day)"
        case let (name?, nil, year?): return "\(name) \(year)"
        case let (name?, nil, nil): return name
        case let (nil, _, year?): return String(year)
        default: return nil
        }
    }

    static func humanized(_ role: String) -> String {
        role.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The same actor voices the character in every season, so the raw list
    /// across appearances repeats them; deduped by id, first spelling wins.
    private var voiceActors: [FfiVoiceActor] {
        var seen: Set<Int64> = []
        var unique: [FfiVoiceActor] = []
        for appearance in character.appearances {
            for actor in appearance.voiceActors where seen.insert(actor.id).inserted {
                unique.append(actor)
            }
        }
        return unique
    }
}
