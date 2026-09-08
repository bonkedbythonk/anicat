import SwiftUI
import AnicatCoreKit

/// One member of a film or series cast: who they are, and what else they are
/// in.
///
/// The anime side has had character and staff pages since it had a cast grid;
/// cinema had portraits that did nothing, because a TMDB person id is not an
/// AniList character id and there was no page to open. This is that page.
/// Presented as a sheet rather than pushed onto `personPageStack`, which is
/// AniList's own stack and keyed by its ids.
struct CinemaPersonView: View {
    let model: AppModel
    let personId: Int64
    /// Shown while the fetch runs, so the sheet opens with a name on it
    /// rather than a spinner over nothing.
    let fallbackName: String
    let onDismiss: () -> Void

    @State private var person: CinemaPerson?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let biography = person?.biography {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BIOGRAPHY")
                            .sumiTabularMono(size: 9.5, weight: .bold)
                            .foregroundColor(SumiTheme.muted)
                        Text(biography)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let credits = person?.credits, !credits.isEmpty {
                    known(credits)
                } else if failed {
                    Text("TMDB has nothing more about this person.")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.muted)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SumiTheme.background)
        .task(id: personId) {
            person = await model.cinemaPerson(id: personId)
            failed = person == nil
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
                    .padding(8)
                    .background(SumiTheme.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.sumiPressable)
            .padding(12)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CachedAsyncImage(url: person?.photoUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SumiTheme.card
            }
            .frame(width: 110, height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SumiTheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text(person?.name ?? fallbackName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)

                if let known = person?.knownFor {
                    Text(known.uppercased())
                        .sumiTabularMono(size: 9.5, weight: .bold)
                        .foregroundColor(SumiTheme.muted)
                }

                if let life = lifeLine {
                    Text(life)
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }

                if let place = person?.placeOfBirth {
                    Text(place)
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let imdb = person?.imdbUrl.flatMap(URL.init(string:)) {
                    Link("View on IMDb", destination: imdb)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.indigo)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Born and, where it applies, died. One line rather than two fields:
    /// a date of birth on its own reads as a form, not a biography.
    private var lifeLine: String? {
        guard let birthday = person?.birthday, !birthday.isEmpty else { return nil }
        let born = CinemaDetailsTabSection.date(birthday)
        guard let death = person?.deathday, !death.isEmpty else { return born }
        return "\(born) – \(CinemaDetailsTabSection.date(death))"
    }

    private func known(_ credits: [CinemaCredit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KNOWN FOR")
                .sumiTabularMono(size: 9.5, weight: .bold)
                .foregroundColor(SumiTheme.muted)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 14)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(credits, id: \.catalogId) { credit in
                    Button {
                        onDismiss()
                        Task {
                            await model.openCinemaDetail(
                                catalog: credit.catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv,
                                id: credit.catalogId,
                                title: credit.title,
                                coverURL: credit.coverImage.flatMap(URL.init(string:))
                            )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CachedAsyncImage(url: credit.coverImage.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                SumiTheme.card
                            }
                            .frame(height: 190)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(credit.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let character = credit.character {
                                Text(character)
                                    .font(.system(size: 11))
                                    .foregroundColor(SumiTheme.muted)
                                    .lineLimit(1)
                            }
                            if let year = credit.year {
                                Text(String(year))
                                    .sumiTabularMono(size: 10)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
