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

/// Status filter tabs. Plain words, the active one in indigo on a 15% wash —
/// no underline and no pill border, which is what separates this from the
/// segmented control below.
public struct SumiTabBar: View {
    @Namespace private var tabNamespace
    let tabs: [(key: String, label: String)]
    @Binding var selection: String

    public init(tabs: [(key: String, label: String)], selection: Binding<String>) {
        self.tabs = tabs
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.key) { tab in
                let isSelected = selection == tab.key
                Button {
                    if selection != tab.key {
                        SumiHaptics.selection()
                        withAnimation(.sumiSpring) {
                            selection = tab.key
                        }
                    }
                } label: {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(isSelected ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                    .fill(SumiTheme.indigo.opacity(0.15))
                                    .matchedGeometryEffect(id: "sumiTabBarHighlight", in: tabNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
        }
        .animation(.sumiSpring, value: selection)
    }
}

/// The joined toggle used for Anime/Manga and Grid/Table: one hairline box
/// with the segments butted together inside it, not separate buttons.
public struct SumiSegmentedControl: View {
    @Namespace private var segmentNamespace
    let options: [(key: String, label: String)]
    @Binding var selection: String

    public init(options: [(key: String, label: String)], selection: Binding<String>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.key) { option in
                let isSelected = selection == option.key
                Button {
                    if selection != option.key {
                        SumiHaptics.selection()
                        withAnimation(.sumiSpring) {
                            selection = option.key
                        }
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Rectangle()
                                    .fill(SumiTheme.indigo.opacity(0.15))
                                    .matchedGeometryEffect(id: "sumiSegmentHighlight", in: segmentNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .animation(.sumiSpring, value: selection)
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
        .buttonStyle(.sumiPressable)
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
