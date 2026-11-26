import SwiftUI

/// One action the detail header offers: the primary button, or an item in
/// its More menu.
struct HeaderAction {
    let title: String
    /// Nil for a text-only button: "Add to Planning" has no symbol in the
    /// catalogue, and a name with no drawing renders nothing.
    let icon: String?
    let run: () -> Void
}

/// The list status menu: AniList's statuses, or the local cinema list.
struct HeaderListMenu {
    let title: String
    let options: [(String, () -> Void)]
    /// "Remove from list" for the cinema list. AniList's removal is in More,
    /// because it deletes an entry on a server rather than clearing a word.
    let remove: (() -> Void)?
}

struct HeaderFilmPicker {
    let isPresented: Binding<Bool>
    let isLoading: Bool
    let candidates: [MediaDetailView.ReleaseCandidateItem]
    let onSelect: (String) -> Void
}

/// The header's row: one filled button, then the list status, the heart and
/// More, each in the secondary box. Its own struct rather than more of
/// `MediaDetailView.body`, which already sits at the edge of what the type
/// checker will take.
struct HeaderActionBar: View {
    let primary: HeaderAction?
    let restart: HeaderAction?
    let listMenu: HeaderListMenu
    /// Nil on a cinema page, where AniList's heart has nothing to write to.
    let isFavourite: Bool?
    let onToggleFavourite: () -> Void
    /// The film itself, when the page is one: it has no Episodes tab, so its
    /// download and source picker are in More instead of on a row.
    let film: MediaDetailView.EpisodeItem?
    let onDownloadFilm: (MediaDetailView.EpisodeItem) -> Void
    let onChooseFilmSource: (MediaDetailView.EpisodeItem) -> Void
    /// Flips the film's watched mark; the row tick that did it went with the
    /// Episodes tab.
    let onSetFilmWatched: (MediaDetailView.EpisodeItem) -> Void
    let isCompactList: Binding<Bool>?
    /// `anicat_sub_dub`, in the vocabulary Settings writes ("Subtitled" /
    /// "Dubbed").
    let audio: Binding<String>?
    let removeFromAniList: (() -> Void)?
    let canRemoveFromAniList: Bool
    let filmPicker: HeaderFilmPicker

    var body: some View {
        HStack(spacing: 8) {
            if let primary {
                Button(action: primary.run) {
                    if let icon = primary.icon {
                        Label(primary.title, anicat: icon)
                    } else {
                        Text(primary.title)
                    }
                }
                .sumiPrimaryButton()
                .controlSize(.extraLarge)
                // Anchored to the button the film plays from; the menu item
                // that opens it has gone by the time the picker shows.
                .sumiPopover(isPresented: filmPicker.isPresented, arrowEdge: .bottom) {
                    ServerPickerView(
                        isLoading: filmPicker.isLoading,
                        candidates: filmPicker.candidates,
                        onSelect: filmPicker.onSelect
                    )
                }
            }

            Menu {
                ForEach(Array(listMenu.options.enumerated()), id: \.offset) { _, option in
                    Button(option.0, action: option.1)
                }
                if let remove = listMenu.remove {
                    Divider()
                    Button("Remove from list", action: remove)
                }
            } label: {
                HeaderMenuLabel(title: listMenu.title, showsChevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if let isFavourite {
                Button(action: onToggleFavourite) {
                    Image(anicat: isFavourite ? "heart.fill" : "heart")
                        .foregroundColor(isFavourite ? SumiTheme.favourite : SumiTheme.muted)
                }
                .sumiSecondaryButton()
                .controlSize(.extraLarge)
                .help(isFavourite ? "Remove from favourites" : "Add to favourites")
            }

            if hasMoreItems {
                Menu {
                    moreItems
                } label: {
                    HeaderMenuLabel(title: nil, showsChevron: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }

            Spacer(minLength: 0)
        }
    }

    private var hasMoreItems: Bool {
        restart != nil || film != nil || isCompactList != nil || audio != nil || removeFromAniList != nil
    }

    @ViewBuilder
    private var moreItems: some View {
        if let restart {
            Button(restart.title, action: restart.run)
        }
        if let film {
            Button(film.isWatched ? "Mark unwatched" : "Mark watched") { onSetFilmWatched(film) }
            Button("Download") { onDownloadFilm(film) }
            Button("Choose source…") { onChooseFilmSource(film) }
        }
        if let isCompactList {
            Divider()
            Toggle("Compact episode list", isOn: isCompactList)
        }
        if let audio {
            Divider()
            ForEach(MediaDetailView.AudioType.allCases, id: \.self) { type in
                Toggle(type.rawValue, isOn: Binding(
                    get: { MediaDetailView.AudioType(stored: audio.wrappedValue) == type },
                    set: { if $0 { audio.wrappedValue = type.storedValue } }
                ))
            }
        }
        if let removeFromAniList {
            Divider()
            Button(role: .destructive, action: removeFromAniList) {
                Label("Remove from AniList", anicat: "trash")
            }
            .disabled(!canRemoveFromAniList)
        }
    }
}

/// A menu drawn as the secondary button beside it. Under
/// `.borderlessButton` a macOS menu is an NSPopUpButton, which takes its
/// title from the first `Text` in the label only, so the title is a single
/// `Text` and the box is the label's own background, as in
/// `SumiFilterDropdown`.
private struct HeaderMenuLabel: View {
    let title: String?
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let title {
                Text(title)
            }
            Image(anicat: showsChevron ? "chevron.down" : "ellipsis")
                .font(.system(size: showsChevron ? 9 : 13, weight: .semibold))
                .foregroundColor(showsChevron ? SumiTheme.muted : SumiTheme.foreground)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundColor(SumiTheme.foreground)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(SumiTheme.card)
        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            SumiRect(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}
