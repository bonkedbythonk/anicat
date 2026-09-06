import SwiftUI

public struct KeyboardShortcutsOverlay: View {
    public struct ShortcutItem: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let keys: [String]

        public init(id: String, label: String, keys: [String]) {
            self.id = id
            self.label = label
            self.keys = keys
        }
    }

    public struct ShortcutSection: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let items: [ShortcutItem]

        public init(id: String, title: String, items: [ShortcutItem]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    let onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public static let defaultSections: [ShortcutSection] = [
        ShortcutSection(
            id: "navigation",
            title: "Navigation",
            items: [
                ShortcutItem(id: "palette", label: "Command palette", keys: ["⌘", "K"]),
                ShortcutItem(id: "search", label: "Quick search", keys: ["/"]),
                ShortcutItem(id: "sections", label: "Jump to section (1–9)", keys: ["1", "–", "9"]),
                ShortcutItem(id: "home", label: "Up Next", keys: ["H"]),
                ShortcutItem(id: "library", label: "Library", keys: ["L"]),
                ShortcutItem(id: "manga", label: "Manga", keys: ["M"]),
                ShortcutItem(id: "novels", label: "Light Novels", keys: ["N"]),
                ShortcutItem(id: "stats", label: "Stats", keys: ["T"]),
                ShortcutItem(id: "downloads", label: "Downloads", keys: ["D"]),
                ShortcutItem(id: "shortcuts", label: "Show keyboard shortcuts", keys: ["?"]),
                ShortcutItem(id: "dismiss", label: "Dismiss overlay or view", keys: ["Esc"])
            ]
        ),
        ShortcutSection(
            id: "player",
            title: "Player",
            items: [
                ShortcutItem(id: "playpause", label: "Play / pause", keys: ["Space"]),
                ShortcutItem(id: "seekback", label: "Seek backward 10s", keys: ["←"]),
                ShortcutItem(id: "seekfwd", label: "Seek forward 10s", keys: ["→"]),
                ShortcutItem(id: "anime4k", label: "Toggle Anime4K upscaling", keys: ["Ctrl", "1"])
            ]
        ),
        ShortcutSection(
            id: "manga_reader",
            title: "Manga reader",
            items: [
                ShortcutItem(id: "closereader", label: "Exit reader", keys: ["Esc"])
            ]
        )
    ]

    public var body: some View {
        ZStack {
            // Scrim provides an explicit tap target for dismiss without requiring Escape key awareness.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                header
                Rectangle().fill(SumiTheme.border).frame(height: 1)
                shortcutsList
            }
            .frame(maxWidth: 540)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .contentShape(Rectangle())
            .onTapGesture {
                // Absorbs clicks within the card to prevent dismiss triggering through to the scrim.
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
        .sumiExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.indigo)

            Text("Keyboard Shortcuts")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(SumiTheme.foreground)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 24, height: 24)
                    .background(SumiTheme.foregroundWash)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.sumiPressable)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var shortcutsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.defaultSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .sumiTabularMono(size: 11, weight: .semibold)
                            .foregroundColor(SumiTheme.muted)

                        VStack(spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Text(item.label)
                                        .font(.system(size: 13))
                                        .foregroundColor(SumiTheme.foreground.opacity(0.9))

                                    Spacer()

                                    HStack(spacing: 4) {
                                        ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                                            if key == "–" {
                                                Text("–")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(SumiTheme.muted)
                                            } else {
                                                KeyBadge(text: key)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 7)

                                if index < section.items.count - 1 {
                                    Rectangle()
                                        .fill(SumiTheme.border.opacity(0.5))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxHeight: 460)
    }
}

private struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(SumiTheme.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SumiTheme.foregroundWash)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
    }
}
