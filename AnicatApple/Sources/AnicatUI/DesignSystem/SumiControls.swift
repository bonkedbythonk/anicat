import SwiftUI

/// The shared chrome the views are built from, so a tab bar in the Library and
/// one in Search are the same control rather than two lookalikes that drift.

/// Page heading: a 19pt semibold title over an uppercase mono subtitle, with
/// controls pinned to the trailing edge. Every top-level view uses it.
public struct SumiPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
    }
}

public extension SumiPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Status filter tabs. Plain words, the active one in indigo on a 15% wash —
/// no underline and no pill border, which is what separates this from the
/// segmented control below.
public struct SumiTabBar: View {
    let tabs: [(key: String, label: String)]
    @Binding var selection: String

    public init(tabs: [(key: String, label: String)], selection: Binding<String>) {
        self.tabs = tabs
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.key) { tab in
                Button {
                    selection = tab.key
                } label: {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(selection == tab.key ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selection == tab.key ? SumiTheme.indigo.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// The joined toggle used for Anime/Manga and Grid/Table: one hairline box
/// with the segments butted together inside it, not separate buttons.
public struct SumiSegmentedControl: View {
    let options: [(key: String, label: String)]
    @Binding var selection: String

    public init(options: [(key: String, label: String)], selection: Binding<String>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.key) { option in
                Button {
                    selection = option.key
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selection == option.key ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selection == option.key ? SumiTheme.indigo.opacity(0.15) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// The hairline-over-ground button: "Pick for me", "Browse all manga",
/// "Shuffle". Never filled — a fill here competes with the one accent control
/// a screen is allowed.
public struct SumiOutlineButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(SumiTheme.foreground.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A labelled dropdown for a filter row: "Any" plus a fixed option list,
/// where the empty string means "no filter" rather than a real value — kept
/// distinct from `SettingsView`'s private `SumiDropdown` because a filter
/// needs a clearable "Any" state that a settings picker never does.
public struct SumiFilterDropdown: View {
    let label: String
    let options: [(value: String, label: String)]
    @Binding var selected: String

    public init(label: String, options: [(value: String, label: String)], selected: Binding<String>) {
        self.label = label
        self.options = options
        self._selected = selected
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selected })?.label ?? "Any"
    }

    public var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selected = option.value
                } label: {
                    HStack {
                        Text(option.label)
                        if option.value == selected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                // A `Menu` under `.menuStyle(.borderlessButton)` renders as an
                // NSPopUpButton on macOS, which only honors the FIRST `Text`
                // in the label — a second sibling `Text` (the selected value)
                // silently never draws, so picking a filter looked like it
                // did nothing even though the search itself re-ran correctly.
                // `+` concatenates into one `Text` node instead of two, which
                // NSPopUpButton's title extraction does pick up.
                (Text(label).foregroundColor(SumiTheme.muted)
                    + Text(" " + selectedLabel)
                        .foregroundColor(selected.isEmpty ? SumiTheme.foreground.opacity(0.6) : SumiTheme.indigo))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected.isEmpty ? Color.clear : SumiTheme.indigo.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(selected.isEmpty ? SumiTheme.border : SumiTheme.indigo.opacity(0.4), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A dashed-outline panel for "this list is empty". Dashed rather than solid
/// so an empty list never reads as a card with content that failed to paint.
public struct SumiEmptyState: View {
    let headline: String
    let detail: String?

    public init(headline: String, detail: String? = nil) {
        self.headline = headline
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .strokeBorder(SumiTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

/// A shelf heading: 15pt semibold with a mono count on the right.
public struct SumiSectionHeader: View {
    let title: String
    let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(SumiTheme.foreground)
            Spacer()
            if let trailing {
                Text(trailing)
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
        }
    }
}

/// The six-column poster grid the Library and Search results share.
public struct SumiPosterGrid: View {
    let items: [MediaCard.Item]
    let onSelect: (MediaCard.Item) -> Void

    public init(items: [MediaCard.Item], onSelect: @escaping (MediaCard.Item) -> Void) {
        self.items = items
        self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(items) { item in
                MediaCard(item: item) { onSelect(item) }
            }
        }
    }
}

/// The standard page container: 40pt gutters, 40/32 top and bottom, capped at
/// 1100pt so shelves do not stretch the full width of a large window.
public struct SumiPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SumiTheme.background)
    }
}
