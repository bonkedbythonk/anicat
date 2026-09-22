import SwiftUI
import AnicatCoreKit

/// The `.manga` tab. Split out of `tabContent` alongside the other tabs
/// below so switching tabs, or any one tab's own state changing, only
/// re-evaluates that tab's struct instead of the whole detail page body.
struct MangaTabSection: View {
    /// Volumes of a light novel, or an honest word about why there are none.
    ///
    /// This tab used to say reading "isn't available yet" for every novel,
    /// because nothing resolved a catalogue entry to a source at all. Most
    /// AniList light novels still have no indexed English translation, so a
    /// miss stays a first-class outcome rather than an error.
    @ViewBuilder
    var novelVolumeList: some View {
        if !lnoriEnabled {
            // Downloaded volumes stay listed under the card: they are read
            // from disk and never reach the site the switch is about.
            VStack(alignment: .leading, spacing: 12) {
                lnoriDisabledCard
                if !novelVolumes.isEmpty {
                    LazyVStack(spacing: 8) {
                        ForEach(novelVolumes, id: \.url) { volume in
                            volumeRow(volume)
                        }
                    }
                }
            }
        } else if isLoadingNovelVolumes {
            EpisodeListSkeleton(count: 4, isCompact: true)
        } else if !novelVolumes.isEmpty {
            LazyVStack(spacing: 8) {
                ForEach(novelVolumes, id: \.url) { volume in
                    volumeRow(volume)
                }
            }
        } else if novelSourceMissing {
            SumiEmptyState(
                headline: "No readable copy found",
                detail: "No English translation of this novel is indexed. Titles that are translated open here; the rest can still be read by pasting a Syosetu link into the Light Novels page."
            )
        } else {
            SumiEmptyState(
                headline: "No chapters found",
                detail: "Nothing readable was found for this title."
            )
        }
    }

    /// Why the list is empty before the switch has ever been touched, and
    /// the switch itself: the reason and the choice on one card, so turning
    /// it on is not a trip to Settings and back. Same dashed frame as the
    /// miss state above; `SumiEmptyState` has no slot for a control.
    private var lnoriDisabledCard: some View {
        VStack(spacing: 8) {
            Text("Official volumes are off")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text("Official volumes come from a third-party site that hosts licensed light novels. It is off until you turn it on.")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Text("Official volumes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                lnoriSwitch
            }
            .padding(.top, 6)
            Text("Web novels from Syosetu are unaffected.")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .strokeBorder(SumiTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    @ViewBuilder
    private var lnoriSwitch: some View {
        // `SwitchToggleStyle` is not in the tvOS SDK. Nothing mounts this tab
        // on the TV; the default style only keeps it compiling there.
        #if os(tvOS)
        Toggle("Official volumes", isOn: $lnoriEnabled)
            .labelsHidden()
        #else
        Toggle("Official volumes", isOn: $lnoriEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        #endif
    }

    @ViewBuilder
    private func volumeRow(_ volume: NovelChapterRef) -> some View {
        let state = novelVolumeStates[volume.url] ?? .none
        HStack(spacing: 12) {
            Button { onReadVolume?(volume) } label: {
                HStack(spacing: 12) {
                    Image(systemName: state == .stored ? "book.closed.fill" : "book.closed")
                        .font(.system(size: 13))
                        .foregroundColor(state == .stored ? SumiTheme.indigo : SumiTheme.muted)
                        .frame(width: 20)
                    Text(volume.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            volumeAction(
                systemImage: state == .stored ? "checkmark.circle.fill" : "arrow.down.circle",
                help: state == .stored ? "Downloaded. Click to remove." : "Keep this volume for reading offline",
                busy: state == .downloading,
                tint: state == .stored ? SumiTheme.indigo : SumiTheme.muted
            ) {
                if state == .stored {
                    onDeleteVolumeDownload?(volume)
                } else {
                    onDownloadVolume?(volume)
                }
            }

            // Export is offered whether or not the volume is downloaded: it
            // downloads first when it has to, so sending a book to a reader is
            // one action rather than two in an order the user has to know.
            volumeAction(
                systemImage: "square.and.arrow.up",
                help: "Save as an EPUB for an e-reader",
                busy: state == .exporting,
                tint: SumiTheme.muted
            ) {
                onExportVolume?(volume)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func volumeAction(
        systemImage: String,
        help: String,
        busy: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundColor(tint)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(busy)
        .help(help)
    }

    let chapters: [MediaDetailView.MangaChapterItem]
    let format: String?
    var isLoading: Bool = false
    // `AppModel.isLnoriEnabled` owns the reader and the default (off);
    // `@AppStorage` needs a literal here, so the two must agree.
    @AppStorage("anicat_lnori_enabled") private var lnoriEnabled: Bool = false
    var novelVolumes: [NovelChapterRef] = []
    var isLoadingNovelVolumes: Bool = false
    var novelSourceMissing: Bool = false
    var onReadVolume: ((NovelChapterRef) -> Void)?
    var novelVolumeStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadVolume: ((NovelChapterRef) -> Void)?
    var onDeleteVolumeDownload: ((NovelChapterRef) -> Void)?
    var onExportVolume: ((NovelChapterRef) -> Void)?
    /// Which chapters are on disk, or on their way there. Keyed by chapter
    /// id because that is what the registry and the files are keyed on.
    var offlineStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadChapter: ((MediaDetailView.MangaChapterItem) -> Void)?
    var onDeleteChapterDownload: ((MediaDetailView.MangaChapterItem) -> Void)?
    let onReadChapter: (MediaDetailView.MangaChapterItem) -> Void

    var body: some View {
        if chapters.isEmpty {
            if isLoading {
                EpisodeListSkeleton(count: 6, isCompact: true)
            } else if format == "NOVEL" {
                novelVolumeList
            } else {
                SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(chapters) { chapter in
                    MediaDetailView.ChapterRowView(
                        chapter: chapter,
                        offline: offlineStates[chapter.id] ?? .none,
                        onDownload: onDownloadChapter.map { action in { action(chapter) } },
                        onDeleteDownload: onDeleteChapterDownload.map { action in { action(chapter) } }
                    ) {
                        onReadChapter(chapter)
                    }
                }
            }
        }
    }
}
