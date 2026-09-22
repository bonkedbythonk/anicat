import SwiftUI
import AnicatCoreKit

/// What the detail page can ask of the studio catalog: open a studio's own
/// page, and list its works for the "More from" shelf.
///
/// Handed down the environment rather than added to `MediaDetailView.init`,
/// which already takes two dozen parameters and is built at one call site
/// with no other interest in studios. The default is inert, so a preview or
/// a test that renders the page without an app around it draws the studio
/// names as plain buttons and no shelf, rather than failing on a dependency
/// it never asked for.
public struct StudioPageActions: Sendable {
    public var open: @MainActor @Sendable (Int64) -> Void
    public var works: @MainActor @Sendable (Int64) async -> [MediaDetailView.StudioWorkItem]

    public init(
        open: @escaping @MainActor @Sendable (Int64) -> Void = { _ in },
        works: @escaping @MainActor @Sendable (Int64) async -> [MediaDetailView.StudioWorkItem] = { _ in [] }
    ) {
        self.open = open
        self.works = works
    }
}

struct StudioPageActionsKey: EnvironmentKey {
    static let defaultValue = StudioPageActions()
}

public extension EnvironmentValues {
    var studioPageActions: StudioPageActions {
        get { self[StudioPageActionsKey.self] }
        set { self[StudioPageActionsKey.self] = newValue }
    }
}

/// One studio name in the meta line, sized to sit inside that mono line
/// rather than break it: no capsule and no padding of its own, just the
/// hover colour and underline that say the name is a destination.
struct StudioButton: View {
    let name: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Text(name)
                .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.muted)
                .underline(isHovered, color: SumiTheme.indigo.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isHovered = $0 }
        .animation(.sumi(.pop), value: isHovered)
    }
}
