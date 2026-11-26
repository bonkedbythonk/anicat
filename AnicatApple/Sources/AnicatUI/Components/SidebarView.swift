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
            case (.novels, _): return "Light novels"
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
    /// Off while nothing on the viewer's Watching list is airing: the
    /// calendar then only lists shows they do not follow, and the owner does
    /// not use it in that state. The section itself stays on Go > Cmd-2.
    public let showsSchedule: Bool
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    public init(
        currentView: Binding<NavSection>,
        mode: AppModel.AppMode = .anime,
        showsSchedule: Bool = true,
        onOpenSearchPalette: @escaping () -> Void
    ) {
        self._currentView = currentView
        self.mode = mode
        self.showsSchedule = showsSchedule
        self.onOpenSearchPalette = onOpenSearchPalette
    }

    /// Night City and Evangelion draw the rail as a HUD list; every other skin
    /// keeps the Mac source-list look.
    private var isHud: Bool {
        ThemeStore.shared.palette.isCyber || ThemeStore.shared.palette.isEva
    }

    /// The rail is 64pt of icons, not a 200pt list of words. With four or five
    /// destinations the list left most of its height empty, and the owner
    /// picked the icon rail over filling it: a second list of titles beside
    /// the shelves "you just get too much double in 1 screen". Names live in
    /// each button's tooltip and accessibility label.
    ///
    /// 72, not the mockup's 64: the window's traffic lights are fixed by the
    /// system at about 10-62pt from the left edge, and in 64 they sat 4pt
    /// right of centre with almost no margin on the right.
    public static let width: CGFloat = 72

    /// One rail icon per place, not per section. Manga, light novels and the
    /// cinema pages are reached from the media switch in the page header, and
    /// Stats from Profile's, so the rail holds what the mockups show. The
    /// sections themselves stay: they number the Cmd-1..9 shortcuts and the
    /// `anicat://section/` links, and removing a case renumbers both.
    private var topItems: [NavSection] {
        let home: NavSection = mode == .cinema ? .manga : .upNext
        var items: [NavSection] = [home, .search, .library]
        if mode == .anime, showsSchedule || currentView == .schedule {
            items.append(.schedule)
        }
        return items
    }

    /// The rail icon a section lights up: the page-header switches keep the
    /// icon of the place they belong to lit.
    private func railOwner(of section: NavSection) -> NavSection {
        switch (section, mode) {
        case (.manga, .anime), (.novels, .anime): return .upNext
        case (.novels, .cinema), (.upNext, .cinema): return .manga
        case (.stats, _): return .history
        default: return section
        }
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Window drag region: the traffic lights sit over the top of the rail.
            Color.clear
                .frame(height: 38)

            RailButton(
                symbol: "magnifyingglass",
                label: "Search anything (⌘K)",
                isActive: false,
                action: onOpenSearchPalette
            )
            Color.clear.frame(height: 6)

            ForEach(topItems) { item in
                navItemButton(item)
            }

            Spacer()

            ForEach([NavSection.downloads, .history, .settings]) { item in
                navItemButton(item)
            }
        }
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .background {
            if isHud {
                // Solid, not the system material: the page picture behind the
                // window shows through it, and a vibrancy layer would blur and
                // tint it back to grey.
                SumiTheme.card.opacity(0.9)
            } else {
                VibrancyBackdrop()
            }
        }
    }

    private func navItemButton(_ item: NavSection) -> some View {
        let label = item == .manga && mode == .cinema ? "Home" : item.placeName(for: mode)
        let isActive = railOwner(of: currentView) == item
        return RailButton(symbol: item.symbol(for: mode), label: label, isActive: isActive) {
            #if os(macOS)
            // Settings is its own window on the Mac (see the scene in
            // AnicatApp); the gear opens it rather than swapping the page.
            if item == .settings {
                openSettings()
                return
            }
            #endif
            // Set even when already lit: the binding's setter is what closes
            // an open detail or person page, so a click on the current
            // place's icon has to reach it to get back to the page itself.
            if !isActive { SumiHaptics.selection() }
            withAnimation(.snappy(duration: 0.3)) {
                currentView = item
            }
        }
    }

    private struct RailButton: View {
        let symbol: String
        let label: String
        let isActive: Bool
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            let hud = ThemeStore.shared.palette.isCyber || ThemeStore.shared.palette.isEva
            Button(action: action) {
                Image(anicat: symbol)
                    .font(.system(size: 17, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive
                        ? (hud ? SumiTheme.indigo : SumiTheme.foreground)
                        : (isHovered ? SumiTheme.foreground : SumiTheme.muted))
                    .frame(width: 40, height: 40)
                    // The same rounded wash a source list uses to mark its row.
                    .background {
                        if isActive || isHovered {
                            SumiRect(cornerRadius: SumiTheme.radiusMd)
                                .fill(SumiTheme.isNeon && isActive
                                    ? SumiTheme.indigo.opacity(0.14)
                                    : SumiTheme.foreground.opacity(isActive ? 0.08 : 0.04))
                                .overlay {
                                    if hud && isActive {
                                        SumiRect(cornerRadius: SumiTheme.radiusMd)
                                            .stroke(SumiTheme.indigo.opacity(0.6), lineWidth: 1)
                                    }
                                }
                                .sumiGlow(radius: isActive ? 8 : 0, opacity: 0.25)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
        }
    }
}

extension SidebarView.NavSection {
    /// What the rail's tooltips and the Go menu call a section: the places of
    /// the redesign rather than the old rows ("Anime", "Search", "History"),
    /// so the menu and the rail name the same page the same way.
    public func placeName(for mode: AppModel.AppMode) -> String {
        switch self {
        case .upNext: return "Up next"
        case .search: return "Discover"
        case .history: return "Profile"
        default: return label(for: mode)
        }
    }

    /// The rail icon. Names are Anicat's own drawings, keyed by the SF Symbol
    /// each replaced; a name with no drawing renders nothing, so every one
    /// here exists in `Resources/Symbols.xcassets`.
    func symbol(for mode: AppModel.AppMode) -> String {
        switch (self, mode) {
        case (.manga, .cinema): return "film.stack"
        case (.novels, .cinema): return "tv"
        case (.upNext, _): return "play.square.stack"
        case (.schedule, _): return "calendar"
        case (.library, _): return "rectangle.stack"
        case (.manga, _): return "book.closed"
        case (.novels, _): return "book"
        case (.search, _): return "safari"
        case (.history, _): return "person.crop.circle"
        case (.stats, _): return "chart.bar"
        case (.downloads, _): return "arrow.down.circle"
        case (.settings, _): return "gearshape"
        }
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

    private static let mark = Image.bundledPNG("anicat_logo")
}
