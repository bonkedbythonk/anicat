import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct SidebarView: View {
    public enum NavSection: String, CaseIterable, Identifiable {
        case upNext = "home"
        case schedule = "schedule"
        case library = "lists"
        case manga = "manga"
        case novels = "novels"
        case search = "search"
        case history = "profile"
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
            case .downloads: return "D"
            default: return nil
            }
        }
    }

    @Binding public var currentView: NavSection
    public let onOpenSearchPalette: () -> Void

    private let browseItems: [NavSection] = [
        .upNext, .schedule, .library, .manga, .novels, .search, .history
    ]

    private let systemItems: [NavSection] = [
        .downloads, .settings
    ]

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
                    navGroup(title: "Browse", items: browseItems)

                    // Group: System
                    navGroup(title: "System", items: systemItems)
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
                SumiLogoMark()
                    .frame(height: 80)
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
                }
                .buttonStyle(.plain)
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
        let isActive = currentView == item

        return Button(action: {
            currentView = item
        }) {
            HStack {
                Text(item.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.7))

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
            .background(isActive ? SumiTheme.indigo.opacity(0.10) : Color.clear)
            .overlay(
                // 2px solid left accent indicator matching Tauri CSS
                Rectangle()
                    .fill(isActive ? SumiTheme.indigo : Color.clear)
                    .frame(width: 2),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
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
        #if os(macOS)
        for case let url? in candidates {
            if let nsImage = NSImage(contentsOf: url) { return Image(nsImage: nsImage) }
        }
        #else
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                return Image(uiImage: uiImage)
            }
        }
        #endif
        return nil
    }()
}
