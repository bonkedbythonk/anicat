import SwiftUI
import AnicatCoreKit

/// Mounts whatever sits on top of `AppModel.personPageStack`, plus the
/// chrome all three pages share (back button, loading, error, the
/// "Open on AniList" parity link). RootView only has to ask whether the
/// stack is empty.
public struct PersonPageView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        PersonPageScaffold(
            anilistURL: model.personPageStack.last?.anilistURL,
            onBack: { model.closePersonPage() }
        ) {
            if let error = model.personPageError {
                PersonPageErrorState(message: error) { model.retryPersonPage() }
            } else if model.isPersonPageLoading {
                PersonPageLoadingState()
            } else {
                switch model.personPageStack.last {
                case .character:
                    if let character = model.loadedCharacter {
                        CharacterDetailView(
                            character: character,
                            onOpenStaff: { model.openStaff(id: $0) },
                            onOpenTitle: { appearance in
                                model.openTitleFromPersonPage(
                                    id: appearance.catalogId,
                                    title: appearance.title,
                                    coverURL: URL(string: appearance.coverImage),
                                    isManga: PersonPageView.isManga(mediaType: appearance.mediaType, format: appearance.format)
                                )
                            }
                        )
                    } else {
                        PersonPageLoadingState()
                    }
                case .staff:
                    if let staff = model.loadedStaff {
                        StaffDetailView(
                            staff: staff,
                            onOpenCharacter: { model.openCharacter(id: $0) },
                            onOpenTitle: { catalogId, title, cover, mediaType, format in
                                model.openTitleFromPersonPage(
                                    id: catalogId,
                                    title: title,
                                    coverURL: URL(string: cover),
                                    isManga: PersonPageView.isManga(mediaType: mediaType, format: format)
                                )
                            }
                        )
                    } else {
                        PersonPageLoadingState()
                    }
                case .thread:
                    if let thread = model.loadedThread {
                        ThreadView(
                            thread: thread,
                            comments: model.loadedThreadComments,
                            hasMoreComments: model.threadHasMoreComments,
                            isLoadingMore: model.isLoadingMoreThreadComments,
                            onLoadMore: { model.loadMoreThreadComments() }
                        )
                    } else {
                        PersonPageLoadingState()
                    }
                case nil:
                    EmptyView()
                }
            }
        }
    }

    /// AniList's `mediaType` is the authority here — a character page mixes
    /// anime and manga appearances, and `format` alone reads "TV"/"MOVIE"
    /// for one and "MANGA"/"NOVEL" for the other with no shared vocabulary.
    static func isManga(mediaType: String?, format: String?) -> Bool {
        if let mediaType { return mediaType.uppercased() == "MANGA" }
        return AppModel.isMangaFormat(format)
    }
}

// MARK: - Shared chrome

struct PersonPageScaffold<Content: View>: View {
    let anilistURL: URL?
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isBackHovered = false

    var body: some View {
        SumiPage {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundColor(isBackHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isBackHovered = $0 }
            .animation(.snappy, value: isBackHovered)

            content()

            if let anilistURL {
                Button {
                    Platform.openExternal(anilistURL)
                } label: {
                    HStack(spacing: 5) {
                        Text("Open on AniList")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .padding(.top, 8)
            }
        }
    }
}

struct PersonPageLoadingState: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading")
                .sumiTabularMono(size: 11)
                .foregroundColor(SumiTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 100)
    }
}

struct PersonPageErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            SumiEmptyState(headline: "Couldn't load this page", detail: message)
            SumiOutlineButton("Try again", systemImage: "arrow.clockwise", action: onRetry)
        }
    }
}

// MARK: - Shared rows

/// A poster + title + year card, the unit both the character page's
/// "Appearances" grid and the staff page's "Works" grid are made of.
struct PersonMediaPoster: View {
    let title: String
    let coverImage: String
    let year: Int32?
    let caption: String?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: URL(string: coverImage), maxPixelSize: 400) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(isHovered ? SumiTheme.indigo.opacity(0.6) : SumiTheme.border, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if let year {
                            Text(String(year))
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted)
                        }
                        if let caption, !caption.isEmpty {
                            Text(caption)
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
    }
}

/// A circular portrait with a name and an optional second line, used for
/// voice actors on a character page and for characters on a staff page.
struct PersonAvatarChip: View {
    let name: String
    let imageURL: String?
    let caption: String?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                CachedAsyncImage(url: imageURL.flatMap(URL.init(string:)), maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(SumiTheme.card)
                }
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(Circle().stroke(isHovered ? SumiTheme.indigo.opacity(0.6) : SumiTheme.border, lineWidth: 1))

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .sumiTabularMono(size: 9)
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovered ? SumiTheme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(isHovered ? SumiTheme.border : SumiTheme.border.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
    }
}

/// The large left-hand portrait shared by the character and staff pages.
struct PersonPortrait: View {
    let imageURL: String?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: imageURL.flatMap(URL.init(string:)), maxPixelSize: 500) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .frame(width: 200)
    }
}

/// The uppercase mono label every section on these pages is headed with,
/// matching the "SEASONS & ADAPTATIONS" heading in the Related tab.
struct PersonSectionLabel: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .sumiTabularMono(size: 11)
                .foregroundColor(SumiTheme.indigo)
            if let trailing {
                Text(trailing)
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }
}
