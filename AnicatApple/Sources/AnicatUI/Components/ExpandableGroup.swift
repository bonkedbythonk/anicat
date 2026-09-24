import SwiftUI

/// A collapsible group whose whole header row opens and closes it. The
/// system `DisclosureGroup` on macOS answers only its small chevron, not the
/// label beside it (owner, on the chapter groups: "clicking the expand
/// button is really hard"), and it is not in the tvOS SDK at all.
struct ExpandableGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content()
            }
        }
    }
}

extension Binding where Value == Bool {
    /// Whether `key` is in `set`, written back by inserting or removing it.
    init<Key: Hashable & Sendable>(member key: Key, of set: Binding<Set<Key>>) {
        self.init(
            get: { set.wrappedValue.contains(key) },
            set: { open in
                if open { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) }
            }
        )
    }
}
