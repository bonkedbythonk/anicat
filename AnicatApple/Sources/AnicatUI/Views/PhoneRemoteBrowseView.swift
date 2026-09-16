#if os(iOS)
import SwiftUI

/// Picking what the Mac plays, from the phone.
///
/// Everything here is answered by the *phone's* own catalog, not by asking
/// the Mac: both devices are signed into the same AniList account and the
/// phone already holds Up Next and can search, so a browse protocol would be
/// a second copy of a list this app has in memory, one round trip further
/// away and able to disagree with it.
///
/// The Mac is only told what to open, as an `anicat://` address through
/// `RemoteCommand.open`, so it resolves and resumes with its own registry --
/// which is the one that knows where playback on that machine left off.
struct PhoneRemoteBrowseView: View {
    let node: BonjourDiscovery.DiscoveredNode
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MediaCard.Item] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// The row just sent, so the list can say the tap landed. The Mac takes a
    /// moment to resolve, and without this the sheet looks like it ignored
    /// the press.
    @State private var sentTitle: String?

    private var episodeQueue: [UpNextQueueView.QueueEntry] {
        model.upNextItems.filter { $0.unit == "EP" }
    }

    var body: some View {
        NavigationStack {
            List {
                if let sentTitle {
                    Section {
                        Label("Sent \(sentTitle) to \(node.name)", systemImage: "checkmark.circle")
                            .foregroundStyle(SumiTheme.muted)
                    }
                }

                if query.isEmpty {
                    Section("Up Next") {
                        if episodeQueue.isEmpty {
                            Text("Nothing in the queue")
                                .foregroundStyle(SumiTheme.muted)
                        }
                        ForEach(episodeQueue) { entry in
                            row(
                                title: entry.title,
                                detail: "Episode \(entry.nextEpisodeOrChapter)",
                                cover: entry.thumbnailURL
                            ) {
                                send(
                                    .play(id: entry.id, episode: entry.nextEpisodeOrChapter),
                                    named: entry.title
                                )
                            }
                        }
                    }
                } else {
                    Section(isSearching ? "Searching" : "Results") {
                        if !isSearching, results.isEmpty {
                            Text("Nothing found")
                                .foregroundStyle(SumiTheme.muted)
                        }
                        ForEach(results) { item in
                            row(
                                title: item.title,
                                // A search result carries no episode to
                                // resume, so the Mac is sent to the page and
                                // the choice of episode is made there -- or
                                // from the queue above, once it has one.
                                detail: "Open on \(node.name)",
                                cover: item.coverImageURL
                            ) {
                                send(
                                    .title(id: item.id, isManga: item.isManga),
                                    named: item.title
                                )
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search AniList")
            .onChange(of: query) { _, new in scheduleSearch(new) }
            .navigationTitle("Play on \(node.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func row(
        title: String,
        detail: String,
        cover: URL?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: cover, maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(SumiTheme.foreground)
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(SumiTheme.muted)
                }
                Spacer()
                Image(systemName: "play.circle")
                    .foregroundStyle(SumiTheme.indigo)
            }
        }
    }

    private func send(_ link: DeepLink, named title: String) {
        RemoteClient.shared.send(.open(link: link.url.absoluteString), to: node)
        sentTitle = title
        // Back to the transport, which is what the tap was for. The list
        // stayed open with a confirmation line on it, so the thing that had
        // just been started was behind two sheets and the Mac's resolve
        // finished with nobody watching it.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            dismiss()
        }
    }

    /// Debounced, and run against the engine directly rather than through
    /// `AppModel.search`: that writes `searchResults`, which is the Search
    /// tab's own state, and typing here would wipe what the user left open
    /// there.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let engine = model.engine else { return }
            let summaries = try? await engine.searchCatalog(
                query: trimmed,
                mediaType: "ANIME",
                filters: nil,
                page: 1
            )
            guard !Task.isCancelled else { return }
            results = (summaries ?? []).map { AppModel.card($0) }
            isSearching = false
        }
    }
}
#endif
