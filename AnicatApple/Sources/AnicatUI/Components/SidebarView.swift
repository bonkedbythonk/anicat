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

        public var label: String {
            switch self {
            case .upNext: return "Up Next"
            case .schedule: return "Schedule"
            case .library: return "Library"
            case .manga: return "Manga"
            case .novels: return "Light Novels"
            case .search: return "Search"
            case .history: return "History"
            case .stats: return "Stats"
            case .downloads: return "Downloads"
            case .settings: return "Settings"
            }
        }

        public var shortcut: String? {
            switch self {
            case .upNext: return "H"
            case .library: return "L"
            case .manga: return "M"
            case .novels: return "N"
            case .search: return "/"
            case .stats: return "T"
            case .downloads: return "D"
            default: return nil
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

        public static let systemItems: [NavSection] = [.downloads, .settings]

        /// The order the rail actually draws, which is not `numberedSections`
        /// — that list ends Settings, Downloads, while the rail renders
        /// Browse then System and so ends Downloads, Settings. The section
        /// entrance slides in the direction of travel down this list, so
        /// reading the numbered order there sent the last two sections the
        /// wrong way.
        public static let displayOrder: [NavSection] = browseItems + systemItems

        public var displayIndex: Int {
            Self.displayOrder.firstIndex(of: self) ?? 0
        }

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
    public let onOpenSearchPalette: () -> Void
    @Namespace private var sidebarNavNamespace

    public init(currentView: Binding<NavSection>, onOpenSearchPalette: @escaping () -> Void) {
        self._currentView = currentView
        self.onOpenSearchPalette = onOpenSearchPalette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window Drag Region Spacer (38px on macOS for traffic lights)
            Color.clear
                .frame(height: 38)

            // Scrollable Nav Groups
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Group: Browse
                    navGroup(title: "Browse", items: NavSection.browseItems)

                    // Group: System
                    navGroup(title: "System", items: NavSection.systemItems)
                }
                .padding(.bottom, 8)
            }

            Spacer()

            // Bottom Logo & Search Button
            VStack(spacing: 12) {
                // The actual mark, not a glyph that resembles one: `h-20`
                // (80pt), grayscaled, at `opacity-10`. An SF Symbol cat is a
                // different drawing at a different weight and reads as a
                // placeholder next to the real logo.
                VStack(spacing: 6) {
                    SumiLogoMark()
                        .frame(height: 80)
                    // The mode caption under the mark. It names which of the
                    // two worlds the app is in; the switch itself only appears
                    // once cinema mode is enabled, so this is a label rather
                    // than a control here.
                    Text("Anime and manga")
                        .sumiTabularMono(size: 9)
                        .foregroundColor(SumiTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                // Search Bar Button (⌘K)
                Button(action: onOpenSearchPalette) {
                    HStack {
                        Text("Search anything")
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)

                        Spacer()

                        // Bare text, no chip. The web's ⌘K here carries
                        // `meta-mono` and nothing else; boxing it made the
                        // control read as two nested buttons.
                        Text("⌘K")
                            .sumiTabularMono(size: 9)
                            .foregroundColor(SumiTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
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
            Text(title.uppercased())
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
        NavItemButton(item: item, isActive: currentView == item, namespace: sidebarNavNamespace) {
            if currentView != item {
                SumiHaptics.selection()
                AppSounds.tabChange.play()
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
        let isActive: Bool
        let namespace: Namespace.ID
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack {
                    Text(item.label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? SumiTheme.foreground : (isHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.7)))

                    Spacer()

                    if let sc = item.shortcut {
                        // The chip is `meta-mono` at its full 11.5pt, and it — not
                        // the label — sets the row height: measured against the
                        // running Tauri app, a row with a shortcut is 37pt and one
                        // without is 34. Shrinking the chip to 10pt compressed
                        // every row and the whole list drifted short of the web.
                        Text(sc)
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SumiTheme.foreground.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(SumiTheme.border.opacity(0.5), lineWidth: 1)
                            )
                    }
                }
                .frame(minHeight: 23)
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.vertical, 7)
                .background {
                    if isActive {
                        SumiTheme.indigo.opacity(0.10)
                            .matchedGeometryEffect(id: "sidebarNavBackground", in: namespace)
                    } else if isHovered {
                        SumiTheme.foreground.opacity(0.04)
                    }
                }
                .overlay(alignment: .leading) {
                    if isActive {
                        Rectangle()
                            .fill(SumiTheme.indigo)
                            .frame(width: 2)
                            .matchedGeometryEffect(id: "sidebarNavIndicator", in: namespace)
                    }
                }
                .animation(.snappy, value: isHovered)
                .animation(.snappy(duration: 0.3), value: isActive)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
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

    private static let mark: Image? = {
        let candidates = [
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png", subdirectory: "Images"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) {
                return Image(platformImage: image)
            }
        }
        return nil
    }()
}
