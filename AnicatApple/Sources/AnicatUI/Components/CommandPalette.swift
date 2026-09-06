import SwiftUI

/// The ⌘K palette: type to filter, Return to go.
///
/// Sits above everything as its own layer rather than inside a view, because
/// it is reachable from every section and has to survive the section changing
/// under it.
public struct CommandPalette: View {
    public struct Command: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let group: String
        public let action: @Sendable () -> Void

        public init(id: String, label: String, group: String = "Navigate", action: @escaping @Sendable () -> Void) {
            self.id = id
            self.label = label
            self.group = group
            self.action = action
        }
    }

    let commands: [Command]
    let onDismiss: () -> Void
    /// Live show search, debounced below — kept separate from `commands`
    /// (a fixed, synchronous list of nav shortcuts) since this one is async
    /// and per-keystroke. `nil` (the default) means no show search is wired
    /// up: the placeholder still says "Search shows, actions, pages" either
    /// way, but only a caller that passes this actually searches shows.
    var onSearchTitles: ((String) async -> [Command])?

    @State private var query = ""
    @State private var highlighted = 0
    @State private var titleMatches: [Command] = []
    @FocusState private var fieldFocused: Bool

    public init(
        commands: [Command],
        onSearchTitles: ((String) async -> [Command])? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.commands = commands
        self.onSearchTitles = onSearchTitles
        self.onDismiss = onDismiss
    }

    private var matches: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        // Title matches first: with a query typed, a specific show is almost
        // always what's being looked for, not "Go to Home".
        return titleMatches + commands.filter { $0.label.lowercased().contains(q) }
    }

    /// Groups in the order their first command appears, so the list does not
    /// reshuffle as the query narrows it.
    private var groups: [String] {
        var seen: [String] = []
        for command in matches where !seen.contains(command.group) {
            seen.append(command.group)
        }
        return seen
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // The scrim is the dismiss target. Without it the only way out is
            // Escape, which is not discoverable.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                field
                if !matches.isEmpty {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                    results
                }
            }
            .frame(maxWidth: 620)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, 140)
        }
        .onAppear { fieldFocused = true }
        .sumiExitCommand(perform: onDismiss)
        // `.task(id:)` cancels the previous debounce automatically when
        // `query` changes again — same pattern as the Search tab's own
        // `.task(id: searchText)` — so only the last keystroke in a burst
        // actually fires a search.
        .task(id: query) {
            guard let onSearchTitles else { return }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                titleMatches = []
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await onSearchTitles(trimmed)
            guard !Task.isCancelled else { return }
            titleMatches = found
        }
    }

    private var field: some View {
        HStack(spacing: 12) {
            TextField("Search shows, actions, pages", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.foreground)
                .focused($fieldFocused)
                .onSubmit(runHighlighted)
                .onChange(of: query) { _, _ in highlighted = 0 }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.indigo.opacity(0.7), lineWidth: 1)
                )

            Text("esc")
                .sumiTabularMono(size: 10)
                .foregroundColor(SumiTheme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
        }
        .padding(14)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.self) { group in
                    Text(group)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(matches.filter { $0.group == group }) { command in
                        let index = matches.firstIndex(where: { $0.id == command.id }) ?? 0
                        Button {
                            onDismiss()
                            command.action()
                        } label: {
                            Text(command.label)
                                .font(.system(size: 14))
                                .foregroundColor(SumiTheme.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(index == highlighted ? SumiTheme.indigo.opacity(0.12) : Color.clear)
                                .animation(.snappy, value: highlighted == index)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .onHover { hovering in
                            if hovering { highlighted = index }
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 380)
    }

    private func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        let command = matches[highlighted]
        onDismiss()
        command.action()
    }
}
