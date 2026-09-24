import SwiftUI

/// The shared chrome the views are built from, so a tab bar in the Library and
/// one in Search are the same control rather than two lookalikes that drift.

/// Page heading: a 19pt semibold title over a mono subtitle, with
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
                    .font(.sumiHeading(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .contentTransition(.numericText())
                        .animation(.sumiSpring, value: subtitle)
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

/// Status filter tabs as words: the chosen one in ink and semibold, the rest
/// muted, no background. It slid an indigo wash between tabs, the motion
/// already removed from the sidebar and Settings.
public struct SumiTabBar: View {
    let tabs: [(key: String, label: String)]
    @Binding var selection: String

    public init(tabs: [(key: String, label: String)], selection: Binding<String>) {
        self.tabs = tabs
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 16) {
            ForEach(tabs, id: \.key) { tab in
                let isSelected = selection == tab.key
                Button {
                    if selection != tab.key {
                        SumiHaptics.selection()
                        withAnimation(.snappy) { selection = tab.key }
                    }
                } label: {
                    // Sized by an invisible semibold copy, as in
                    // `SumiSlashToggle`: the weight change alone shifted
                    // every tab after the chosen one sideways.
                    Text(tab.label)
                        .fontWeight(.semibold)
                        .hidden()
                        .overlay {
                            Text(tab.label)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .font(.system(size: 12.5))
    }
}

/// Two or three choices as words, "Sub / Dub": the chosen one in ink and
/// semibold, the rest muted. It replaced the system segmented picker, grey
/// stock chrome that did not look like the rest of Anicat, and before that
/// a hand-drawn row with a sliding indigo highlight, the web's toggle-group.
public struct SumiSlashToggle<Option: Hashable>: View {
    let options: [(Option, String)]
    let selection: Option
    let select: (Option) -> Void

    public init(_ options: [(Option, String)], selection: Option, select: @escaping (Option) -> Void) {
        self.options = options
        self.selection = selection
        self.select = select
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Text("/").foregroundColor(SumiTheme.muted.opacity(0.6))
                }
                let isOn = option.0 == selection
                Button {
                    if !isOn {
                        SumiHaptics.selection()
                        select(option.0)
                    }
                } label: {
                    // Sized by an invisible semibold copy: the weight change
                    // alone shifted every word after the chosen one sideways
                    // on each switch.
                    Text(option.1)
                        .fontWeight(.semibold)
                        .hidden()
                        .overlay {
                            Text(option.1)
                                .fontWeight(isOn ? .semibold : .regular)
                                .foregroundColor(isOn ? SumiTheme.foreground : SumiTheme.muted)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .font(.system(size: 12.5))
        .fixedSize()
    }
}

/// The joined toggle used for Anime/Manga, Grid/Table and the other
/// one-of-a-few choices, keyed by string.
public struct SumiSegmentedControl: View {
    let options: [(key: String, label: String)]
    @Binding var selection: String

    public init(options: [(key: String, label: String)], selection: Binding<String>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        SumiSlashToggle(options.map { ($0.key, $0.label) }, selection: selection) { key in
            withAnimation(.snappy) { selection = key }
        }
    }
}

/// The secondary push button: "Browse all manga", "Shuffle". Never
/// prominent -- that competes with the one primary action a screen is allowed.
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
                    Image(systemName: systemImage)
                }
            }
        }
        .sumiSecondaryButton()
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

/// "This list is empty" as a plain sentence where the content would be. It
/// was a dashed drop-zone box with 80pt of padding, a web upload target that
/// about twenty screens drew.
public struct SumiEmptyState: View {
    let headline: String
    let detail: String?

    public init(headline: String, detail: String? = nil) {
        self.headline = headline
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundColor(SumiTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
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
                .font(.sumiHeading(size: 15, weight: .semibold))
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
    let namespace: Namespace.ID?
    // Which card (if any) is the poster-morph source, as "<shelfKey>:<id>".
    // Gated per-card here rather than passing `namespace` straight through,
    // since the same title can be visible in more than one grid/shelf on
    // the same screen — see `AppModel.openingDetailSourceKey`.
    let openingSourceKey: String?
    let shelfKey: String
    let onSelect: (MediaCard.Item) -> Void

    public init(
        items: [MediaCard.Item],
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        shelfKey: String = "grid",
        onSelect: @escaping (MediaCard.Item) -> Void
    ) {
        self.items = items
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.shelfKey = shelfKey
        self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(items) { item in
                MediaCard(
                    item: item,
                    namespace: openingSourceKey == "\(shelfKey):\(item.id)" ? namespace : nil
                ) { onSelect(item) }
            }
        }
    }
}

/// The standard page container: 40pt gutters, 40/32 top and bottom, and the
/// same centred column as the home page (`SumiContentWidth`). It was pinned
/// left under a flat 1200pt cap, so in a wide window Manga and Light Novels
/// started at a different x from Anime next to them.
public struct SumiPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    // Computed: a generic type cannot hold a static stored property.
    static var horizontalInset: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 40
        #endif
    }

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                // 40pt is a window gutter; on a 402pt phone it left 322pt for
                // the person pages' grids, one column of a 190pt-minimum grid.
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(SumiTheme.background)
    }
}

/// A horizontal row that wraps onto further lines instead of running past its
/// container. `HStack` does neither: the search filter row's widest Anime
/// state ("Genre Slice of Life", "Status Not Yet Released", "Sort Title A-Z"
/// and "Clear filters" all at once) measures wider than the 1020pt of content
/// the page's 1100pt cap leaves after its 40pt gutters, so the trailing
/// dropdowns and the clear button were pushed off the right edge with nothing
/// to scroll them back into view.
public struct SumiWrapHStack: Layout {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : size.width + spacing
            // An empty line takes the subview whatever its width: a single
            // item wider than `maxWidth` would otherwise be moved to a fresh
            // line it does not fit on either, forever.
            if !current.indices.isEmpty, current.width + advance > maxWidth {
                result.append(current)
                current = Line(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width += advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { result.append(current) }
        return result
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(subviews, maxWidth: maxWidth)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
