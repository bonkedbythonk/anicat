#if os(tvOS)
import SwiftUI
import AnicatCoreKit

/// The top of `AppModel.personPageStack` on the TV: a character, a voice
/// actor or other staff member, or a studio. Every row on it leads
/// somewhere else -- character to voice actor to that actor's other roles
/// to their shows -- so the cast on a detail page is never a dead end.
///
/// Its own view rather than `PersonPageView`: that one is drawn for a
/// pointer and a thumb, with pressable styles that show no focus at all on
/// tvOS. Forum threads are not here; the TV detail page lists no
/// discussions, so nothing on the TV opens one.
struct TVPersonView: View {
    @Bindable var model: AppModel
    /// The first card of the first row. Focus is put there whenever a page
    /// loads: the page underneath is disabled, but tvOS left focus with it
    /// rather than moving it here, and no press reached the new page.
    @FocusState private var focused: Int64?

    private var firstCardID: Int64? {
        switch model.personPageStack.last {
        case .character:
            guard let c = model.loadedCharacter else { return nil }
            return c.appearances.flatMap(\.voiceActors).first?.id ?? c.appearances.first?.catalogId
        case .staff:
            guard let s = model.loadedStaff else { return nil }
            return s.characterCredits.first?.characters.first?.id ?? s.mediaCredits.first?.catalogId
        case .studio:
            return model.loadedStudio?.media.first?.catalogId
        default:
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let character = model.loadedCharacter, case .character = model.personPageStack.last {
                    characterPage(character)
                } else if let staff = model.loadedStaff, case .staff = model.personPageStack.last {
                    staffPage(staff)
                } else if let studio = model.loadedStudio, case .studio = model.personPageStack.last {
                    studioPage(studio)
                } else if let error = model.personPageError {
                    VStack(alignment: .leading, spacing: 24) {
                        TVEmptyHint(title: "Could not load this page", detail: error)
                        Button("Try again") { model.retryPersonPage() }
                            .padding(.horizontal, TVMetrics.gutter)
                    }
                    .padding(.top, 200)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 300)
                }
            }
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .background(SumiTheme.background.ignoresSafeArea())
        // Back steps down the stack -- voice actor, then the character,
        // then the title -- rather than dropping the whole chain at once.
        .onExitCommand { model.closePersonPage() }
        .task(id: firstCardID) {
            if let firstCardID { focused = firstCardID }
        }
    }

    // MARK: Character

    @ViewBuilder
    private func characterPage(_ c: FfiCharacterDetail) -> some View {
        header(
            imageURL: c.imageUrl,
            name: c.name,
            native: c.nativeName,
            facts: [c.gender, c.age.map { "Age \($0)" }, c.favourites > 0 ? "\(c.favourites) favourites" : nil],
            description: c.description
        )

        // Voice actors across every appearance, once each, Japanese first:
        // the same actor voices a character in every season.
        let actors = Self.unique(c.appearances.flatMap(\.voiceActors)).sorted {
            ($0.language == "Japanese" ? 0 : 1) < ($1.language == "Japanese" ? 0 : 1)
        }
        if !actors.isEmpty {
            row("Voiced by") {
                ForEach(actors, id: \.id) { actor in
                    TVPersonCard(imageURL: actor.imageUrl, title: actor.name, subtitle: actor.language, focus: $focused, focusID: actor.id) {
                        model.openStaff(id: actor.id)
                    }
                }
            }
        }

        if !c.appearances.isEmpty {
            row("Appears in") {
                ForEach(c.appearances, id: \.catalogId) { a in
                    TVPersonCard(
                        imageURL: a.coverImage,
                        title: a.title,
                        subtitle: [a.year.map(String.init), a.characterRole.map(MediaCard.displayRelation)]
                            .compactMap { $0 }.joined(separator: " \u{00B7} "),
                        focus: actors.isEmpty ? $focused : nil,
                        focusID: a.catalogId
                    ) {
                        model.openTitleFromPersonPage(id: a.catalogId, title: a.title, coverURL: URL(string: a.coverImage), isManga: a.mediaType == "MANGA")
                    }
                }
            }
        }
    }

    private static func unique(_ actors: [FfiVoiceActor]) -> [FfiVoiceActor] {
        var seen = Set<Int64>()
        return actors.filter { seen.insert($0.id).inserted }
    }

    // MARK: Staff

    @ViewBuilder
    private func staffPage(_ s: FfiStaffDetail) -> some View {
        header(
            imageURL: s.imageUrl,
            name: s.name,
            native: s.nativeName,
            facts: [s.primaryOccupations.isEmpty ? nil : s.primaryOccupations.joined(separator: ", "), s.language, s.homeTown],
            description: s.description
        )

        // One card per character, opening that character: the path from a
        // voice actor to the rest of their roles.
        let roles = s.characterCredits.compactMap { credit in
            credit.characters.first.map { (credit, $0) }
        }
        if !roles.isEmpty {
            row("Roles") {
                ForEach(roles, id: \.1.id) { credit, character in
                    TVPersonCard(imageURL: character.imageUrl, title: character.name, subtitle: credit.title, focus: $focused, focusID: character.id) {
                        model.openCharacter(id: character.id)
                    }
                }
            }
        }

        if !s.mediaCredits.isEmpty {
            row("Staff work") {
                ForEach(s.mediaCredits, id: \.catalogId) { m in
                    TVPersonCard(imageURL: m.coverImage, title: m.title, subtitle: m.staffRole, focus: roles.isEmpty ? $focused : nil, focusID: m.catalogId) {
                        model.openTitleFromPersonPage(id: m.catalogId, title: m.title, coverURL: URL(string: m.coverImage), isManga: m.mediaType == "MANGA")
                    }
                }
            }
        }
    }

    // MARK: Studio

    @ViewBuilder
    private func studioPage(_ studio: FfiStudioDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(studio.name)
                .font(.sumiHeading(size: 64, weight: .bold))
                .foregroundStyle(SumiTheme.foreground)
            Text(studio.isAnimationStudio ? "Animation studio" : "Studio")
                .font(.system(size: 26))
                .foregroundStyle(SumiTheme.muted)
        }
        .padding(.horizontal, TVMetrics.gutter)

        row("Works") {
            ForEach(studio.media, id: \.catalogId) { m in
                TVPersonCard(imageURL: m.coverImage, title: m.title, subtitle: nil, focus: $focused, focusID: m.catalogId) {
                    model.openTitleFromPersonPage(id: m.catalogId, title: m.title, coverURL: URL(string: m.coverImage), isManga: AppModel.isMangaFormat(m.format))
                }
            }
        }
    }

    // MARK: Pieces

    private func header(imageURL: String?, name: String, native: String?, facts: [String?], description: String?) -> some View {
        HStack(alignment: .top, spacing: 60) {
            CachedAsyncImage(url: imageURL.flatMap(URL.init(string:)), maxPixelSize: 600) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SumiTheme.card
            }
            .frame(width: 300, height: 450)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 14) {
                Text(name)
                    .font(.sumiHeading(size: 60, weight: .bold))
                    .foregroundStyle(SumiTheme.foreground)
                if let native, !native.isEmpty {
                    Text(native)
                        .font(.system(size: 28))
                        .foregroundStyle(SumiTheme.muted)
                }
                let line = facts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 24))
                        .foregroundStyle(SumiTheme.muted)
                }
                if let about = Self.plain(description) {
                    Text(about)
                        .font(.system(size: 24))
                        .lineSpacing(6)
                        .foregroundStyle(SumiTheme.foreground.opacity(0.85))
                        .lineLimit(8)
                        .frame(maxWidth: 1200, alignment: .leading)
                        .padding(.top, 10)
                }
            }
        }
        .padding(.horizontal, TVMetrics.gutter)
    }

    /// The bio's paragraphs as plain text. Spoilers and images are left
    /// out: there is no way to reveal one with a remote short of a button
    /// per spoiler, and a bio's spoilers are the parts not to show unasked.
    private static func plain(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let text = AniListMarkdown.parse(raw).compactMap { block -> String? in
            if case .paragraph(let p) = block { return String(p.characters) }
            return nil
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                    content()
                }
                .padding(.horizontal, TVMetrics.gutter)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A portrait card that opens something: a character, a voice actor, a
/// title. Poster-sized, with the name under it rather than on it, like
/// `TVPosterCard`.
struct TVPersonCard: View {
    let imageURL: String?
    let title: String
    let subtitle: String?
    /// Set by `TVPersonView` on its first row, so it can place focus.
    var focus: FocusState<Int64?>.Binding? = nil
    var focusID: Int64 = 0
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            focusable(Button(action: action) {
                CachedAsyncImage(url: imageURL.flatMap(URL.init(string:)), maxPixelSize: 600) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: TVMetrics.posterWidth, height: TVMetrics.posterHeight)
                .clipped()
            }
            .buttonStyle(.card)
            .accessibilityLabel(title))

            Text(title)
                .font(.system(size: 22))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(2, reservesSpace: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 18))
                    .foregroundStyle(SumiTheme.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: TVMetrics.posterWidth, alignment: .leading)
    }

    @ViewBuilder
    private func focusable(_ button: some View) -> some View {
        if let focus {
            button.focused(focus, equals: focusID)
        } else {
            button
        }
    }
}
#endif
