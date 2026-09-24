import SwiftUI

public struct SidebarView: View {
    public enum NavSection: String, CaseIterable, Identifiable, Sendable {
        case upNext = "home"
        case schedule = "schedule"
        case library = "lists"
        case manga = "manga"
        case novels = "novels"
        case search = "search"
        case history = "profile"
        case stats = "stats"
        case downloads = "downloads"
        case settings = "settings"

        public var id: String { rawValue }

        public var label: String { label(for: .anime) }

        /// The rail's wording per mode. Cinema renames rather than adds: a
        /// new case would renumber the 1-9 shortcuts (see
        /// `numberedSections`) and leave `displayOrder` wrong for whichever
        /// mode was not listed, for three headings that mean the same thing.
        public func label(for mode: AppModel.AppMode) -> String {
            switch (self, mode) {
            case (.upNext, .cinema): return "Home"
            // Films and Series reuse the cases anime spends on Manga and
            // Light Novels rather than adding two of their own: a new case
            // renumbers every 1-9 shortcut (see `numberedSections`), and
            // these two are unused in cinema anyway. Same split by kind the
            // anime rail makes, and the same shape of page behind it.
            case (.manga, .cinema): return "Films"
            case (.novels, .cinema): return "Series"
            case (.library, .cinema): return "Watching"
            case (.upNext, _): return "Anime"
            case (.schedule, _): return "Schedule"
            case (.library, _): return "Library"
            case (.manga, _): return "Manga"
            case (.novels, _): return "Light Novels"
            case (.search, _): return "Search"
            case (.history, _): return "History"
            case (.stats, _): return "Stats"
            case (.downloads, _): return "Downloads"
            case (.settings, _): return "Settings"
            }
        }

        /// The 1-9 keys, in the order they were bound. Appended to, never
        /// inserted into: `fromNumberKey` caps at nine, so a new case slotted
        /// in the middle would silently renumber every shortcut a user has
        /// already learned rather than take the next free digit.
        public static let numberedSections: [NavSection] = [
            .upNext, .schedule, .library, .manga, .novels, .search, .history, .settings, .downloads, .stats
        ]

        public static let browseItems: [NavSection] = [
            .upNext, .schedule, .library, .manga, .novels, .search, .history, .stats
        ]

        /// Manga and light novels are AniList's and have no cinema
        /// counterpart -- they are absent there rather than empty.
        public static func browseItems(for mode: AppModel.AppMode) -> [NavSection] {
            switch mode {
            case .anime: return browseItems
            // No Coming Soon: TMDB dates a season, not an episode, so there
            // is no calendar to build behind it -- its two rows belong in
            // Films and Series, which is where they now are.
            // No Home either: with the resume queue on Watching it was the
            // Films and Series shelves a second time under a different word.
            case .cinema: return [.manga, .novels, .library, .search, .history, .stats]
            }
        }

        public static func displayOrder(for mode: AppModel.AppMode) -> [NavSection] {
            browseItems(for: mode) + systemItems
        }

        /// The digit keys, for the mode showing. Against the shared list,
        /// pressing 4 in cinema would open Manga -- a section not in the rail
        /// and with nothing in it here.
        public static func fromNumberKey(_ num: Int, mode: AppModel.AppMode) -> NavSection? {
            switch mode {
            case .anime: return fromNumberKey(num)
            case .cinema:
                let sections = displayOrder(for: mode)
                guard num >= 1, num <= 9, num <= sections.count else { return nil }
                return sections[num - 1]
            }
        }

        public static func fromLetterKey(_ char: Character, mode: AppModel.AppMode) -> NavSection? {
            if mode == .cinema {
                // F and S rather than M and N: the two cases carry cinema's
                // own labels here, and nobody presses M for Films.
                switch char.lowercased() {
                case "f": return .manga
                case "s": return .novels
                case "l": return .library
                case "t": return .stats
                case "d": return .downloads
                default: return nil
                }
            }
            guard let section = fromLetterKey(char) else { return nil }
            return browseItems(for: mode).contains(section) || systemItems.contains(section)
                ? section
                : nil
        }

        public static let systemItems: [NavSection] = [.downloads, .settings]

        /// Capped at 9 rather than at `numberedSections.count`: the list is
        /// now longer than the digits there are keys for, and a bare count
        /// bound would claim a "10" nobody can press as a single keystroke.
        /// The tenth entry is reachable by its letter instead.
        public static func fromNumberKey(_ num: Int) -> NavSection? {
            guard num >= 1, num <= 9, num <= numberedSections.count else { return nil }
            return numberedSections[num - 1]
        }

        public static func fromLetterKey(_ char: Character) -> NavSection? {
            switch char.lowercased() {
            case "h": return .upNext
            case "l": return .library
            case "m": return .manga
            case "n": return .novels
            case "t": return .stats
            case "d": return .downloads
            default: return nil
            }
        }
    }

    @Binding public var currentView: NavSection
    public let mode: AppModel.AppMode
    public let onOpenSearchPalette: () -> Void
    /// What the mark at the foot of the rail is showing right now, and what
    /// pressing it switches to. Passed in rather than read from `AppModel`
    /// here so the rail stays a view of its inputs.
    public let modeCaption: String
    public let switchModeCaption: String?
    /// Cinema exists in this build but has no TMDB credential to read with.
    /// The mark stays a control and says so: hidden, it was indistinguishable
    /// from a decorative logo, and the one report this produced was "the
    /// toggle doesn't work" for a toggle that was never drawn.
    public let switchModeLocked: Bool
    public let onSwitchMode: () -> Void
    /// Off while nothing on the viewer's Watching list is airing: the
    /// calendar then only lists shows they do not follow, and the owner does
    /// not use it in that state. The section itself stays on Go > Cmd-2.
    public let showsSchedule: Bool
    @State private var isModeHovered = false

    public init(
        currentView: Binding<NavSection>,
        mode: AppModel.AppMode = .anime,
        // Not "Anime and manga": this mode is also where the light novels
        // are, and a caption that lists two of the three reads as a promise
        // that the third is somewhere else.
        modeCaption: String = "Anime",
        switchModeCaption: String? = nil,
        switchModeLocked: Bool = false,
        showsSchedule: Bool = true,
        onSwitchMode: @escaping () -> Void = {},
        onOpenSearchPalette: @escaping () -> Void
    ) {
        self._currentView = currentView
        self.mode = mode
        self.modeCaption = modeCaption
        self.switchModeCaption = switchModeCaption
        self.switchModeLocked = switchModeLocked
        self.showsSchedule = showsSchedule
        self.onSwitchMode = onSwitchMode
        self.onOpenSearchPalette = onOpenSearchPalette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window Drag Region Spacer (38px on macOS for traffic lights)
            Color.clear
                .frame(height: 38)

            // Nav Groups
            VStack(alignment: .leading, spacing: 0) {
                // Group: Browse
                navGroup(
                    title: "Browse",
                    items: NavSection.browseItems(for: mode).filter { showsSchedule || $0 != .schedule || currentView == .schedule }
                )

                // Group: System
                navGroup(title: "System", items: NavSection.systemItems)
            }
            .padding(.bottom, 8)

            Spacer()

            // Bottom Logo & Search Button
            VStack(spacing: 12) {
                // The actual mark, not a glyph that resembles one: 80pt,
                // grayscaled, at 10% opacity. SF Symbols' `pawprint` is a
                // different drawing at a different weight and reads as a
                // placeholder next to the app icon's paw.
                Group {
                    if switchModeCaption != nil || switchModeLocked {
                        Button(action: onSwitchMode) { modeMark }
                            .buttonStyle(.sumiPressable)
                            #if os(macOS)
                            .onHover { isModeHovered = $0 }
                            #endif
                            .help(switchModeLocked
                                  ? "Cinema needs a TMDB key — open Settings"
                                  : "Switch to \(switchModeCaption ?? "")")
                    } else {
                        modeMark
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                // A row, not a box: outlined, it posed as a text field that
                // opened a palette instead of taking typing.
                Button(action: onOpenSearchPalette) {
                    HStack {
                        Text("Search anything")
                            .font(.system(size: 12.5))
                            .foregroundColor(SumiTheme.muted)
                        Spacer()
                        Text("⌘K")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted.opacity(0.7))
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .overlay(alignment: .top) {
                        Rectangle().fill(SumiTheme.border).frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 200)
        .background(VibrancyBackdrop())
    }

    private func navGroup(title: String, items: [NavSection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.muted)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(items) { item in
                navItemButton(item)
            }
        }
    }

    private func navItemButton(_ item: NavSection) -> some View {
        NavItemButton(item: item, mode: mode, isActive: currentView == item) {
            if currentView != item {
                SumiHaptics.selection()
                // Same curve as the row's own `.animation(value: isActive)`
                // below. `matchedGeometryEffect` only glides while the leaving
                // and arriving rows animate in one transaction, so two
                // different curves here made the highlight jump on whichever
                // side finished first.
                withAnimation(.snappy(duration: 0.3)) {
                    currentView = item
                }
            }
        }
    }

    private struct NavItemButton: View {
        let item: NavSection
        let mode: AppModel.AppMode
        let isActive: Bool
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack {
                    Text(item.label(for: mode))
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? SumiTheme.foreground : (isHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.7)))

                    Spacer()
                }
                .frame(minHeight: 23)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                // A rounded wash inset from the rail's edges, where a source
                // list marks its row. It was an indigo band with a 2pt bar on
                // the left edge that slid from row to row, an admin-dashboard
                // nav more than a Mac sidebar.
                .background {
                    if isActive || isHovered {
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .fill(SumiTheme.foreground.opacity(isActive ? 0.08 : 0.04))
                    }
                }
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
        }
    }
}


extension SidebarView {
    /// The caption under the mark: the mode showing, or -- on hover -- what a
    /// press does, which for a build with no TMDB credential is going to
    /// Settings rather than switching.
    var hoverCaption: String {
        guard isModeHovered else { return modeCaption }
        if switchModeLocked { return "Cinema needs a key" }
        return switchModeCaption.map { "Switch to \($0)" } ?? modeCaption
    }

    /// The mark and the caption under it. The caption names which of the two
    /// worlds the app is in; on hover it names the one a press would move to,
    /// because a logo that is also a switch says nothing about being one.
    ///
    /// Nothing here may change the block's size. The caption is the longer
    /// string on hover ("Switch to cinema" against "Anime"), and left to lay
    /// itself out it wrapped to a second line inside the 200pt rail -- the
    /// VStack grew, the mark slid up, and the whole foot of the sidebar
    /// jumped on every pass of the cursor. One line, its own fixed height,
    /// and the swap crossfades in place.
    @ViewBuilder
    var modeMark: some View {
        VStack(spacing: 6) {
            SumiLogoMark()
                .frame(height: 80)
                .opacity(isModeHovered ? 1.6 : 1)
            Text(hoverCaption)
                .sumiTabularMono(size: 9)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 11)
                .foregroundColor(isModeHovered ? SumiTheme.foreground : SumiTheme.muted)
                .contentTransition(.opacity)
        }
        .animation(.snappy(duration: 0.2), value: isModeHovered)
        .contentShape(Rectangle())
    }
}

/// The sidebar watermark, loaded out of the module bundle by URL.
///
/// `Image(_:bundle:)` looks the name up in an asset catalog, and the logo
/// ships as a loose PNG resource — so the by-name form silently renders
/// nothing and the mark simply vanished from the sidebar. Reading the file
/// is the form that works for a resource that is not in a catalog.
struct SumiLogoMark: View {
    var body: some View {
        Group {
            if let image = Self.mark {
                image
                    .resizable()
                    .scaledToFit()
                    .grayscale(1)
                    .opacity(0.10)
            }
        }
    }

    private static let mark: Image? = {
        let candidates = [
            Bundle.anicatResources.url(forResource: "anicat_logo", withExtension: "png"),
            Bundle.anicatResources.url(forResource: "anicat_logo", withExtension: "png", subdirectory: "Images"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) {
                return Image(platformImage: image)
            }
        }
        return nil
    }()
}
