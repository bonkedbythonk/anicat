import Foundation
import SwiftUI
import Observation
import CoreGraphics
#if os(macOS)
import AppKit

/// The real Anicat content window, set once by `WindowConfigurator` in the
/// app target the moment SwiftUI hands it a window. `NSApp.keyWindow` is
/// racy during any transition where something else (mpv's render view, a
/// sheet, a popover) could briefly hold key status — this is the one
/// reference that's unambiguously "our window" for anything driving it from
/// AnicatUI, like the player's auto-fullscreen.
@MainActor
public enum AppWindow {
    public static weak var main: NSWindow?
    public static var isPlaybackActive: Bool = false

    public static func setToolbarVisible(_ visible: Bool) {
        main?.toolbar = nil
    }

    /// Hides or shows the close, minimize and zoom buttons. Hidden while a
    /// stream is up: see the player mount in `RootView`.
    public static func setTrafficLightsHidden(_ hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            main?.standardWindowButton(kind)?.isHidden = hidden
        }
    }
}
#endif

@Observable
@MainActor
public final class PlayerController {
    /// Written from four places (the transport methods below, mpv's own
    /// `pause` observer in `MpvSurface`, and `AppModel.resolveAndPlay`), so
    /// anything that has to follow every pause edge listens here rather
    /// than at each writer. Fires on real transitions only: `resolveAndPlay`
    /// assigns `true` twice per play and the mpv observer echoes back the
    /// value a transport method just set.
    public var isPlaying: Bool = true {
        didSet {
            if oldValue != isPlaying { onPlayingStateChange?(isPlaying) }
        }
    }
    public var onPlayingStateChange: (@MainActor (_ isPlaying: Bool) -> Void)?
    public var currentTime: Double = 0.0 // seconds
    /// The last chapter of a file has no next chapter to end at, so its
    /// window is bounded by the duration — which mpv reports through its own
    /// property observer, sometimes after `MPV_EVENT_FILE_LOADED` has already
    /// handed over the chapter list. Recomputing here is what gives a
    /// trailing "Preview" chapter a window at all.
    public var duration: Double = 0.0 { // seconds
        didSet {
            guard duration != oldValue, !chapters.isEmpty else { return }
            chapterWindows = PlayerChapters.skipWindows(chapters: chapters, duration: duration)
            applySkipSources()
        }
    }
    public var title: String = ""
    public var episodeNumber: Int = 1
    /// The episode's own title (AniZip's, same source `EpisodeItem.title`
    /// reads elsewhere) — separate from `title`, which is the show's.
    public var episodeTitle: String = ""

    // Decoded video size (post-rotation, post-pixel-aspect-ratio), reported
    // by mpv once the file's opened. The overlay chrome needs this to
    // position itself against the actual letterboxed video rect rather than
    // the whole window — a MacBook's screen aspect ratio rarely matches the
    // video's, so anything padded from the window's own edges (rather than
    // the video's) sits partly over a black bar instead of over the frame.
    public var videoDisplayWidth: Double?
    public var videoDisplayHeight: Double?
    public var videoAspectRatio: Double? {
        guard let w = videoDisplayWidth, let h = videoDisplayHeight, h > 0 else { return nil }
        return w / h
    }

    /// The video surface's own real on-screen size (`MpvRenderView.bounds`),
    /// reported directly by that view rather than measured a second time via
    /// a separate SwiftUI `GeometryReader` — see `reportContainerSize`'s doc
    /// comment on why the two can disagree.
    public var videoContainerSize: CGSize = .zero

    public var isBuffering: Bool = false
    // 0-100, or nil before mpv has reported anything — mirrors mpv's own
    // "cache-buffering-state" property so the spinner can say something
    // (buffering is driven by the torrent pre-buffer gate in core, which is
    // seconds not milliseconds; a bare spinner reads as hung over that long).
    public var bufferingPercent: Int? = nil
    public var volume: Double = 1.0 // 0 to 1
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0

    // Anime4K & Video Quality (Single On/Off toggle from Tauri). No longer
    // surfaced in the player UI — controlled from Settings only — but the
    // underlying mpv shader toggle stays, since Settings still reads/writes
    // the same `anicat_gpu_upscaling` default.
    public var isAnime4KEnabled: Bool = true

    /// Whether reaching the end of an episode should start the next one
    /// automatically. Read by `AppModel.handlePlaybackPositionChange`, set
    /// from the player's own toggle button (see `PlayerBottomBar`) — same
    /// direct-`UserDefaults` pattern as `isAnime4KEnabled` above, session
    /// state on this object with the default mirrored in on init.
    public var autoPlayNextEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoPlayNextEnabled, forKey: "anicat_autoplay_next") }
    }

    public func toggleAutoPlayNext() {
        autoPlayNextEnabled.toggle()
        flashHUD(autoPlayNextEnabled ? "Autoplay next on" : "Autoplay next off", symbol: "play.square.stack")
    }

    public var activeAnime4KPreset: Anime4KPreset {
        get { isAnime4KEnabled ? .on : .off }
        set { isAnime4KEnabled = (newValue != .off) }
    }

    // Episode navigation: set by whoever owns the episode list (AppModel).
    // Kept as optional callbacks + flags rather than the controller reaching
    // back into AppModel, same pattern as onSeek/onSetPause below.
    public var onNextEpisode: (@Sendable () -> Void)?
    public var onPreviousEpisode: (@Sendable () -> Void)?
    public var onSelectEpisode: (@Sendable (_ episodeNumber: Int) -> Void)?
    public var hasNextEpisode: Bool = false
    public var hasPreviousEpisode: Bool = false
    public var episodeList: [MediaDetailView.EpisodeItem] = []

    // Volume/mute/speed callbacks — mirror onSeek/onSetPause: state lives
    // here so the UI can bind to it, the actual mpv property set is wired by
    // MpvSurface's coordinator once it has a live handle.
    public var onSetVolume: (@Sendable (_ volume: Double) -> Void)?
    public var onSetMuted: (@Sendable (_ muted: Bool) -> Void)?
    public var onSetSpeed: (@Sendable (_ rate: Double) -> Void)?

    // Rotate video 90 degrees — mirrors the mpv Lua script's "sideways mode"
    // (Shift+V) in the Tauri build: 0 = off, 1 = 90 CW, 2 = 90 CCW. Session-
    // only, tracks how the screen is physically turned right now rather than
    // a per-show preference, same reasoning as the Lua version.
    public var sidewaysState: Int = 0
    public var onCycleSideways: (@MainActor () -> Void)?

    // Skip windows (chapters first, AniSkip filling what chapters left).
    public var introStartTime: Double? = nil
    public var introEndTime: Double? = nil
    public var isIntroActive: Bool = false
    public var outroStartTime: Double? = nil
    public var outroEndTime: Double? = nil
    public var isOutroActive: Bool = false
    /// mpv's `chapter-list` for the loaded file, in file order. Kept whole
    /// rather than only the skippable entries: the seek bar draws a tick per
    /// chapter and the hover tooltip names whichever one the pointer is over,
    /// and neither cares whether it is skippable.
    public var chapters: [PlayerChapter] = []
    /// What the chapters named. Empty for a release with no chapters, which
    /// is when AniSkip is the only source.
    public var chapterWindows: [SkipWindow] = []
    /// The window `currentTime` is inside, if any, and the one the Skip pill
    /// is showing for (which starts two seconds earlier — see
    /// `SkipWindow.isPending`).
    public var activeSkipWindow: SkipWindow?
    public var pendingSkipWindow: SkipWindow?
    /// Set for a moment after auto-skip jumps a window, so the player can say
    /// what it just skipped. Auto-skip is otherwise completely silent, and a
    /// video that jumps ninety seconds with no explanation reads as a seek
    /// bug rather than a feature.
    public var skipFlashLabel: String?
    /// The relative seek that just happened, for the badge over the
    /// picture. `token` changes on every seek so two jumps in the same
    /// direction re-run the badge's transition rather than merging.
    public struct SeekFlash: Equatable, Sendable {
        public let delta: Double
        public let token: Int
    }
    public private(set) var seekFlash: SeekFlash?
    private var seekFlashTask: Task<Void, Never>?
    private var seekFlashCount = 0
    /// What a toggle in the bar just did, shown over the picture for a
    /// moment. The icon's tint change alone went unnoticed ("i need some
    /// visual confirmation"): the icons are 14 pt in a corner and the eye
    /// is on the picture.
    public struct HUDFlash: Equatable, Sendable {
        public let symbol: String
        public let text: String
        public let token: Int
    }
    public private(set) var hudFlash: HUDFlash?
    private var hudFlashTask: Task<Void, Never>?
    private var hudFlashCount = 0

    public func flashHUD(_ text: String, symbol: String) {
        hudFlashCount += 1
        hudFlash = HUDFlash(symbol: symbol, text: text, token: hudFlashCount)
        hudFlashTask?.cancel()
        hudFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.hudFlash = nil
        }
    }
    private var skipFlashTask: Task<Void, Never>?
    /// The last AniSkip answer for this episode, kept so a chapter list that
    /// arrives after it (or a `setChapters` on a later file) can be merged
    /// against it rather than having overwritten it. Chapters win per kind:
    /// a release that chapters its opening but not its ending still gets the
    /// ending from AniSkip.
    private var aniSkipTimes: AniSkipClient.SkipTimes?
    /// Which windows auto-skip has already jumped, keyed by start time at
    /// 0.1 s resolution. Without a guard per window, seeking backward into an
    /// already-skipped opening (scrubbing, rewatching the sequence) would
    /// immediately auto-skip forward again with no way to actually watch it.
    private var skippedWindowKeys: Set<Int> = []

    /// The chapter windows auto-skip may act on. Drops an "Intro" chapter
    /// that AniSkip contradicts: when the only opening the chapters name is
    /// the alias and AniSkip's opening overlaps it by less than half, the
    /// chapter is the cold open and AniSkip has the song. Measured against
    /// nothing (no AniSkip answer) the chapter stands.
    private var trustedChapterWindows: [SkipWindow] {
        guard let intro = chapterWindows.first(where: { $0.kind == .opening }),
              SkipKind.isIntroAlias(intro.chapterTitle),
              let start = aniSkipTimes?.introStart, let end = aniSkipTimes?.introEnd, end > start
        else { return chapterWindows }
        let overlap = max(0, min(intro.end, end) - max(intro.start, start))
        guard overlap < 0.5 * (intro.end - intro.start) else { return chapterWindows }
        return chapterWindows.filter { $0 != intro }
    }

    /// Every window in play, chapters plus whatever AniSkip filled in.
    public var skipWindows: [SkipWindow] {
        let chapterWindows = trustedChapterWindows
        var windows = chapterWindows
        if !chapterWindows.contains(where: { $0.kind == .opening }),
           let start = aniSkipTimes?.introStart, let end = aniSkipTimes?.introEnd, end > start {
            windows.append(SkipWindow(start: start, end: end, kind: .opening))
        }
        if !chapterWindows.contains(where: { $0.kind == .ending }),
           let start = aniSkipTimes?.outroStart, let end = aniSkipTimes?.outroEnd, end > start {
            windows.append(SkipWindow(start: start, end: end, kind: .ending))
        }
        return windows.sorted { $0.start < $1.start }
    }

    /// Whether the player is currently shrunk into the corner. Mirrored in
    /// from `PlayerView` because the next-episode card must not arm behind a
    /// mini-player: the card is where Cancel lives, and a countdown running
    /// somewhere the viewer cannot see or stop is worse than no card at all.
    /// A minimized player falls back to `AppModel`'s own end-of-episode
    /// auto-next, exactly as before this card existed.
    public var isMiniPlayerActive: Bool = false

    /// Where the ambient glow's picture is coming from right now. The
    /// episode still is the base and is always fetched; frame sampling
    /// replaces it once a `screenshot-raw` has come back cheaply enough, and
    /// hands back to it if the sampler gives up.
    public enum AmbientSource: Sendable, Equatable {
        case none
        case thumbnail
        case frame
    }
    public private(set) var ambientFrame: AmbientFrame?
    public private(set) var ambientSource: AmbientSource = .none
    /// Monotonic, never reset: it is the cross-fade's identity, and a
    /// counter that restarted per episode would make the first frame of a
    /// new episode compare equal to the last of the old one and swap with no
    /// fade at all.
    private var ambientFrameCount = 0
    /// The episode still, held so `ambientSamplingStopped` has something to
    /// fall back to an hour into a session.
    private var ambientStill: CGImage?

    /// A frame the sampler just took. Always wins: it is the live picture.
    public func setAmbientFrame(_ image: CGImage) {
        ambientFrameCount += 1
        ambientFrame = AmbientFrame(id: ambientFrameCount, image: image)
        ambientSource = .frame
    }

    /// Set by the player from the playing episode's still, once per episode.
    public func setAmbientStill(_ image: CGImage?) {
        ambientStill = image
        guard ambientSource != .frame else { return }
        showAmbientStill()
    }

    /// Frame sampling gave up (too slow, or unsupported by this build of
    /// mpv). Falls back to whatever the episode still produced.
    public func ambientSamplingStopped() {
        guard ambientSource == .frame else { return }
        showAmbientStill()
    }

    private func showAmbientStill() {
        guard let ambientStill else {
            ambientFrame = nil
            ambientSource = .none
            return
        }
        ambientFrameCount += 1
        ambientFrame = AmbientFrame(id: ambientFrameCount, image: ambientStill)
        ambientSource = .thumbnail
    }
    public var nextEpisodeCountdown = NextEpisodeCountdown()
    /// How long before the end the card comes up for a file with no outro
    /// window from either source.
    public static let countdownTailSeconds: Double = 30

    // Progress & Playback callbacks for real SQLite recording and libmpv sync
    public var onPositionChange: (@MainActor (_ currentTime: Double, _ duration: Double) -> Void)?
    /// True from the moment `AppModel.resolveAndPlay` commits to a new
    /// episode until mpv reports `MPV_EVENT_FILE_LOADED` for it. mpv keeps
    /// emitting the *outgoing* file's time-pos for the whole resolve (0 to
    /// 10 s, at its last second), and `resolveAndPlay` has already reset
    /// the per-episode flags and moved `episodeNumber` on. Delivered, that
    /// tick read as "episode N+1 is at 99.8%": the 85% line marked the new
    /// episode watched on AniList and the 75% line preloaded N+2, both
    /// within a second of N+1 starting. Position, duration and pause
    /// updates are dropped while this is set.
    public var awaitingNewFile: Bool = false
    public var onPlaybackStopped: (@MainActor () -> Void)?
    public var onSeek: (@Sendable (_ seconds: Double) -> Void)?
    public var onSetPause: (@Sendable (_ paused: Bool) -> Void)?
    public var isScrubbing: Bool = false

    // Info / more-options menu: the audio and subtitle pickers. Not state
    // on this object — the list only means anything for the file mpv has
    // open right now, so the popover asks for it when it opens rather than
    // something keeping a copy in step with every load.
    /// Answers through `completion`, on the main actor, for the same reason
    /// `onSelectAudioLanguage` does: the walk behind it is one blocking mpv
    /// property read per field per track, each waiting on mpv's core lock,
    /// and a release with a dozen subtitle tracks is well over a hundred of
    /// them.
    public var onFetchTracks: (@Sendable (_ completion: @escaping @Sendable @MainActor (_ audio: [PlayerTrack], _ subtitle: [PlayerTrack]) -> Void) -> Void)?
    public var onSelectAudioTrack: (@Sendable (_ id: String) -> Void)?
    /// `nil` is the Off row.
    public var onSelectSubtitleTrack: (@Sendable (_ id: String?) -> Void)?

    /// What this title was last watched with, by language rather than by
    /// track id — ids mean nothing across releases, and the next episode is
    /// a different file from a possibly different group. `AppModel` fills it
    /// from the registry before the stream URL reaches mpv, and `MpvSurface`
    /// applies it on `MPV_EVENT_FILE_LOADED`.
    public struct TrackMemory: Sendable, Equatable {
        public var audioLang: String?
        public var subtitleLang: String?
        /// The track's own name, for a pack shipping two tracks of one
        /// language ("Signs & Songs" beside "Full Subtitles") — the lang
        /// alone cannot tell those apart.
        public var subtitleTitle: String?

        public init(audioLang: String? = nil, subtitleLang: String? = nil, subtitleTitle: String? = nil) {
            self.audioLang = audioLang
            self.subtitleLang = subtitleLang
            self.subtitleTitle = subtitleTitle
        }

        public var isEmpty: Bool {
            audioLang == nil && subtitleLang == nil && subtitleTitle == nil
        }
    }

    public var titleTrackMemory: TrackMemory?
    /// Persists `titleTrackMemory` against the playing title. `nil` is
    /// "forget this title". AppModel owns it: this controller knows the
    /// episode number but not the catalog id the row is keyed by.
    public var onRecordTrackMemory: (@Sendable (_ memory: TrackMemory?) -> Void)?

    /// Records an audio track the viewer picked by hand, merged into
    /// whatever this title already remembers.
    ///
    /// Merged rather than built fresh because the engine takes all three
    /// fields in one call: an audio pick written with a nil subtitle would
    /// forget a subtitle chosen ten minutes earlier. Reading the other half
    /// back off the track list instead is no good either — `refreshTracks`
    /// documents that mpv's selection flags are still the pre-switch ones
    /// for a quarter of a second after a pick.
    public func rememberAudioTrack(_ track: PlayerTrack) {
        var memory = titleTrackMemory ?? TrackMemory()
        memory.audioLang = track.lang
        commit(memory)
    }

    /// `nil` is the Off row, which forgets the subtitle half rather than
    /// pretending to round-trip: a stored row with no language and no title
    /// is indistinguishable from no memory at all, so "off" and "never
    /// chose" cannot both be spelled.
    public func rememberSubtitleTrack(_ track: PlayerTrack?) {
        var memory = titleTrackMemory ?? TrackMemory()
        memory.subtitleLang = track?.lang
        memory.subtitleTitle = track?.title
        commit(memory)
    }

    /// "Forget track choices for this title" — the next play falls back to
    /// the global Sub/Dub rule.
    public func forgetTrackMemory() {
        titleTrackMemory = nil
        onRecordTrackMemory?(nil)
    }

    private func commit(_ memory: TrackMemory) {
        titleTrackMemory = memory.isEmpty ? nil : memory
        onRecordTrackMemory?(titleTrackMemory)
    }

    // The release picker, wired to the same engine call the detail page's
    // "Stream Servers" popover uses. AppModel owns it: this controller
    // knows the episode number but not the catalog id or the search title
    // the indexers have to be asked with.
    /// Answers with the releases and, separately, a message when the search
    /// itself failed — an empty list and a failed search are different
    /// things to say, and the popover has to say them differently.
    public var onListReleases: (@Sendable (_ completion: @escaping @Sendable @MainActor (_ releases: [MediaDetailView.ReleaseCandidateItem], _ failure: String?) -> Void) -> Void)?
    public var onSelectRelease: (@MainActor (_ name: String) -> Void)?
    /// The release the playing file was resolved from, when the viewer
    /// asked for one by name. `nil` after an ordinary play: the auto-pick
    /// races candidates inside the engine and nothing reports back which
    /// one won, so there is no honest row to tick.
    public var currentReleaseName: String?
    /// Picks the audio track matching a Sub/Dub choice on the *loaded* file.
    /// Distinct from `onSelectAudioTrack`: `alang` only applies at file
    /// load, so switching the preference mid-episode has to select the
    /// track by language itself rather than by an id the caller would have
    /// had to read the track list to know. Answers whether a
    /// track in that language existed at all: most nyaa releases carry a
    /// single audio track, so the honest outcome of asking for a dub on one
    /// of those is "nothing here to switch to" — a caller that assumed
    /// success would light its Dub button up over unchanged Japanese audio,
    /// which is the bug this whole path exists to fix.
    /// Answers through `completion`, on the main actor, because the track
    /// walk behind it is a couple of dozen synchronous mpv property reads,
    /// each of which waits on mpv's core lock; done inline on the main
    /// thread that was a visible hitch on every press of the Sub/Dub row.
    public var onSelectAudioLanguage: (@Sendable (_ preferDub: Bool, _ completion: @escaping @Sendable @MainActor (Bool) -> Void) -> Void)?
    
    // Autohide controls timer & state
    public var areControlsVisible: Bool = true
    public var isMenuOpen: Bool = false
    private var autohideTask: Task<Void, Never>?

    public init(title: String = "", episodeNumber: Int = 1) {
        self.title = title
        self.episodeNumber = episodeNumber
        if UserDefaults.standard.object(forKey: "anicat_gpu_upscaling") != nil {
            self.isAnime4KEnabled = UserDefaults.standard.bool(forKey: "anicat_gpu_upscaling")
        }
        if UserDefaults.standard.object(forKey: "anicat_autoplay_next") != nil {
            self.autoPlayNextEnabled = UserDefaults.standard.bool(forKey: "anicat_autoplay_next")
        }
        if UserDefaults.standard.object(forKey: "anicat_autoskip") != nil {
            self.autoSkipEnabled = UserDefaults.standard.bool(forKey: "anicat_autoskip")
        }
        // Settings writes the same three keys through @AppStorage. This
        // controller lives for the whole app, so a copy taken at init was
        // the value for the rest of the session: flipping auto-skip or
        // auto-play in Settings mid-episode changed nothing in the player
        // until relaunch. Mirror the store back in when it changes; the
        // guards keep the didSet writes from ping-ponging.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let d = UserDefaults.standard
            if d.object(forKey: "anicat_autoplay_next") != nil,
               d.bool(forKey: "anicat_autoplay_next") != self.autoPlayNextEnabled {
                self.autoPlayNextEnabled = d.bool(forKey: "anicat_autoplay_next")
            }
            if d.object(forKey: "anicat_autoskip") != nil,
               d.bool(forKey: "anicat_autoskip") != self.autoSkipEnabled {
                self.autoSkipEnabled = d.bool(forKey: "anicat_autoskip")
            }
            if d.object(forKey: "anicat_gpu_upscaling") != nil,
               d.bool(forKey: "anicat_gpu_upscaling") != self.isAnime4KEnabled {
                self.isAnime4KEnabled = d.bool(forKey: "anicat_gpu_upscaling")
            }
        }
    }

    // `nonisolated(unsafe)`: `deinit` is nonisolated and has to reach it.
    // Written once from `init` on the main actor, read once in deinit.
    @ObservationIgnored private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    public func togglePlayPause() {
        isPlaying.toggle()
        showControlsBriefly()
        onSetPause?(!isPlaying)
        if !isPlaying {
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
            #endif
            onPositionChange?(currentTime, duration)
        }
    }

    public func play() {
        if !isPlaying {
            isPlaying = true
            showControlsBriefly()
            onSetPause?(false)
        }
    }

    public func pause() {
        if isPlaying {
            isPlaying = false
            showControlsBriefly()
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
            #endif
            onSetPause?(true)
            onPositionChange?(currentTime, duration)
        }
    }

    public func seek(to seconds: Double) {
        currentTime = max(seconds, 0)
        if duration > 0 {
            currentTime = min(currentTime, duration)
        }
        checkIntroStatus()
        showControlsBriefly()
        onSeek?(currentTime)
        onPositionChange?(currentTime, duration)
    }

    public func seekRelative(by delta: Double) {
        seek(to: currentTime + delta)
        flashSeek(delta)
    }

    private func flashSeek(_ delta: Double) {
        seekFlashCount += 1
        seekFlash = SeekFlash(delta: delta, token: seekFlashCount)
        seekFlashTask?.cancel()
        seekFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self?.seekFlash = nil
        }
    }

    public func toggleAnime4K() {
        isAnime4KEnabled.toggle()
        UserDefaults.standard.set(isAnime4KEnabled, forKey: "anicat_gpu_upscaling")
        showControlsBriefly()
        flashHUD(isAnime4KEnabled ? "Upscaling on" : "Upscaling off", symbol: "sparkles")
    }

    public func cycleAnime4K() {
        toggleAnime4K()
    }

    public func setVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        if volume > 0 { isMuted = false }
        onSetVolume?(volume)
        onSetMuted?(isMuted)
        showControlsBriefly()
    }

    public func toggleMute() {
        isMuted.toggle()
        onSetMuted?(isMuted)
        showControlsBriefly()
    }

    public func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        onSetSpeed?(rate)
        showControlsBriefly()
    }

    public func nextEpisode() {
        guard hasNextEpisode else { return }
        onNextEpisode?()
    }

    public func previousEpisode() {
        guard hasPreviousEpisode else { return }
        onPreviousEpisode?()
    }

    public func selectEpisode(_ number: Int) {
        guard number != episodeNumber else { return }
        onSelectEpisode?(number)
    }

    public func cycleSideways() {
        onCycleSideways?()
        showControlsBriefly()
    }

    public func skipIntro() {
        guard let window = skipWindows.first(where: { $0.kind == .opening }) else { return }
        performSkip(window, flash: false)
    }

    public func skipOutro() {
        guard let window = skipWindows.first(where: { $0.kind == .ending }) else { return }
        performSkip(window, flash: false)
    }

    /// What the Skip pill and its key press do: jump the window the pill is
    /// showing for, which during the two-second lead-in has not started yet.
    /// Landing on its end from before its start skips that lead-in too —
    /// that is what pressing Skip early asks for.
    public func skipPendingWindow() {
        guard let window = pendingSkipWindow ?? activeSkipWindow else { return }
        performSkip(window, flash: false)
    }

    private static func windowKey(_ window: SkipWindow) -> Int {
        Int((window.start * 10).rounded())
    }

    private func performSkip(_ window: SkipWindow, flash: Bool) {
        // Before the seek, never after: `seek` re-enters `checkIntroStatus`,
        // which would find `currentTime` still inside the window on a seek
        // mpv has not applied yet and skip it a second time.
        skippedWindowKeys.insert(Self.windowKey(window))
        if flash {
            flashSkip(window.flashLabel)
        }
        seek(to: window.end)
    }

    private func flashSkip(_ label: String) {
        skipFlashLabel = label
        skipFlashTask?.cancel()
        skipFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.skipFlashLabel = nil
        }
    }

    /// mpv's chapter list for the file that just loaded. Called on every file
    /// load, with an empty list for a release that has no chapters, so the
    /// previous episode's windows cannot survive into this one.
    public func setChapters(_ chapters: [PlayerChapter], duration: Double?) {
        self.chapters = chapters.sorted { $0.time < $1.time }
        chapterWindows = PlayerChapters.skipWindows(chapters: self.chapters, duration: duration)
        skippedWindowKeys.removeAll()
        applySkipSources()
    }

    /// Called by `AniSkipClient`'s result for this episode. Resets the
    /// per-episode auto-skip guards so a freshly loaded episode's intro/outro
    /// can auto-skip again even though a previous episode already did.
    ///
    /// It no longer simply assigns the four fields: it is called with `nil`
    /// on every AniSkip miss, and chapters — which are the better source and
    /// usually arrive first — would have been wiped by that miss.
    public func setAniSkipTimes(_ times: AniSkipClient.SkipTimes?) {
        aniSkipTimes = times
        skippedWindowKeys.removeAll()
        applySkipSources()
    }

    /// Recomputes the intro/outro pair from both sources. Chapters win per
    /// kind rather than wholesale: a release that chapters only its opening
    /// still takes its ending from AniSkip.
    private func applySkipSources() {
        let chapterWindows = trustedChapterWindows
        let chapterIntro = chapterWindows.first { $0.kind == .opening }
        let chapterOutro = chapterWindows.first { $0.kind == .ending }
        introStartTime = chapterIntro?.start ?? aniSkipTimes?.introStart
        introEndTime = chapterIntro?.end ?? aniSkipTimes?.introEnd
        outroStartTime = chapterOutro?.start ?? aniSkipTimes?.outroStart
        outroEndTime = chapterOutro?.end ?? aniSkipTimes?.outroEnd
        checkIntroStatus()
    }

    /// Whether the auto-skip setting should act the moment `currentTime`
    /// enters a skip window, rather than just surfacing the manual "Skip"
    /// button. A real stored property (mirrored to `UserDefaults`, same
    /// pattern as `autoPlayNextEnabled`) rather than a computed read of
    /// `UserDefaults` on every check — Settings' own toggle still writes the
    /// same key, but the player's own toggle button (there wasn't one before)
    /// needs something it can bind to and flip directly.
    /// Off by default on iPhone, on by default on the Mac.
    ///
    /// Not a whim: on a phone the intro is the one moment the viewer already
    /// has a thumb near the screen, and skipping it silently reads as the
    /// app having lost its place. On a desktop, where nobody is holding the
    /// machine, the silent skip is the point. Either default is overridden
    /// the moment `anicat_autoskip` exists.
    public var autoSkipEnabled: Bool = {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }() {
        didSet { UserDefaults.standard.set(autoSkipEnabled, forKey: "anicat_autoskip") }
    }

    public func toggleAutoSkip() {
        autoSkipEnabled.toggle()
        flashHUD(autoSkipEnabled ? "Auto-skip on" : "Auto-skip off", symbol: "forward.frame")
    }

    /// Despite the name (kept to avoid touching every call site), this walks
    /// every skip window — chapter-derived and AniSkip alike — against
    /// `currentTime`, and then gives the next-episode card its tick.
    public func checkIntroStatus() {
        // Nothing here can be trusted mid-resolve. `chapters` is still the
        // outgoing file's — only `MPV_EVENT_FILE_LOADED` replaces it — while
        // `currentTime` and `duration` are already the incoming episode's,
        // both written by `resolveAndPlay` before the load. Auto-skip on that
        // pair jumps a window this file does not have, and `loadFile` reads
        // the seeked `currentTime` straight back as `--start`: the episode
        // opens at a timestamp taken from the previous one's chapter list.
        // That is the failure `awaitingNewFile` exists to prevent, reached
        // through a door its own comment does not cover — the `duration`
        // didSet above, which fires one line after `currentTime` is set.
        guard !awaitingNewFile else {
            activeSkipWindow = nil
            pendingSkipWindow = nil
            isIntroActive = false
            isOutroActive = false
            return
        }

        let windows = skipWindows
        if autoSkipEnabled,
           let active = windows.first(where: { $0.contains(currentTime) }),
           !skippedWindowKeys.contains(Self.windowKey(active)) {
            // `performSkip` seeks, and `seek` re-enters this method with the
            // post-jump position; the rest of this pass would be working
            // from a `currentTime` that no longer exists.
            performSkip(active, flash: true)
            return
        }

        let active = windows.first { $0.contains(currentTime) }
        activeSkipWindow = active
        pendingSkipWindow = windows.first { $0.isPending(at: currentTime) }
        isIntroActive = active?.kind == .opening
        isOutroActive = active?.kind == .ending

        checkNextEpisodeCountdown()
    }

    /// Arms and ticks the next-episode card. The card only fronts the
    /// decision `AppModel` already makes — same setting, same "is there a
    /// next episode" — and adds a window in which the viewer can say no.
    private func checkNextEpisodeCountdown() {
        armNextEpisodeCountdown()
        // Arm first, expire second, in one pass. A window that ends at the
        // end of the file arms the countdown at a position nothing will ever
        // move past — there is no second tick to expire it in.
        if nextEpisodeCountdown.advance(to: currentTime, duration: duration) {
            onNextEpisode?()
        }
    }

    private func armNextEpisodeCountdown() {
        guard nextEpisodeCountdown.phase == .idle,
              Self.isNextEpisodeCardEnabled,
              autoPlayNextEnabled,
              hasNextEpisode,
              !isMiniPlayerActive,
              !awaitingNewFile,
              duration > 0 else { return }
        // The outro window from either source, or the last thirty seconds
        // when neither exists. Auto-skip, when it is on, has already jumped
        // past the ending by the time this runs, so the card arms at the
        // window's end rather than at its start — and where that end is the
        // end of the file, `advance`'s end-of-file condition is what expires
        // it, since no position-seconds remain to count.
        let trigger = outroStartTime ?? (duration - Self.countdownTailSeconds)
        guard currentTime >= trigger else { return }
        nextEpisodeCountdown.arm(at: currentTime)
    }

    /// Dismisses the card for this episode. Any key, a click outside it, or
    /// its own Cancel button.
    public func cancelNextEpisodeCountdown() {
        guard nextEpisodeCountdown.isVisible else { return }
        nextEpisodeCountdown.cancel()
    }

    public func playNextEpisodeNow() {
        guard nextEpisodeCountdown.playNow() else { return }
        onNextEpisode?()
    }

    /// No `@AppStorage` mirror on this object the way auto-skip and
    /// auto-play have: nothing here binds to it, it is read at the one
    /// moment the card would arm, and defaulting an absent key to on is the
    /// whole of its behaviour.
    static var isNextEpisodeCardEnabled: Bool {
        UserDefaults.standard.object(forKey: "anicat_next_up_card") as? Bool ?? true
    }

    public func showControlsBriefly() {
        print("[taps] showControlsBriefly called")
        if !areControlsVisible {
            areControlsVisible = true
        }
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
        autohideTask?.cancel()
        autohideTask = Task {
            // Longer on a phone: 3.5s is comfortable with a pointer already
            // on the controls, but a thumb has to travel, and the controls
            // vanishing mid-reach reads as the tap not having worked.
            #if os(iOS)
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            #else
            try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5s
            #endif
            if !Task.isCancelled && isPlaying && !isScrubbing && !isMenuOpen {
                await MainActor.run {
                    withAnimation(.smooth) {
                        self.areControlsVisible = false
                    }
                    #if os(macOS)
                    NSCursor.setHiddenUntilMouseMoves(true)
                    #endif
                }
            }
        }
    }

    public func cancelAutohide() {
        autohideTask?.cancel()
        autohideTask = nil
        areControlsVisible = true
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        Self.formatTimestamp(seconds)
    }

    /// Shared with the seek bar's hover tooltip, which has to spell a
    /// position the viewer is only pointing at rather than one this object
    /// holds.
    public static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// One track out of mpv's `track-list`, flattened to what the info
/// popover's pickers need. Here rather than in `MpvSurface` so the label
/// and the subtitle preference rule stay outside that file's AppKit and
/// libmpv island: both are pure, and neither can be exercised at all from
/// a test that has to bring up mpv first.
public struct PlayerTrack: Identifiable, Sendable, Hashable {
    /// mpv's own track id, in the string form `aid` and `sid` are set with.
    public let id: String
    public let lang: String?
    public let title: String?
    public let isSelected: Bool
    public let isForced: Bool

    /// The `sid` value that turns subtitles off. mpv spells it as a word,
    /// not an empty string.
    public static let off = "no"

    public init(id: String, lang: String?, title: String?, isSelected: Bool, isForced: Bool) {
        self.id = id
        self.lang = lang
        self.title = title
        self.isSelected = isSelected
        self.isForced = isForced
    }

    /// "English", "English (Signs & Songs)", "Track 3".
    public var label: String {
        if id == Self.off { return "Off" }
        let name = lang.map(Self.languageName)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (trimmed?.isEmpty == false) ? trimmed : nil
        switch (name, detail) {
        case let (name?, detail?): return "\(name) (\(detail))"
        case let (name?, nil): return name
        case let (nil, detail?): return detail
        case (nil, nil): return "Track \(id)"
        }
    }

    /// Spells out the ISO 639 codes a release actually carries. Not
    /// `Locale.localizedString(forLanguageCode:)`: that answers in the
    /// viewer's own language, and the three-letter bibliographic codes
    /// Matroska files are tagged with ("ger", "chi", "dut") are not the
    /// ones it maps. An unlisted code is shown raw rather than guessed at.
    public static func languageName(_ code: String) -> String {
        let key = code.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return languageNames[key] ?? code
    }

    private static let languageNames: [String: String] = [
        "en": "English", "eng": "English", "english": "English",
        "ja": "Japanese", "jp": "Japanese", "jpn": "Japanese", "japanese": "Japanese",
        "es": "Spanish", "spa": "Spanish",
        "fr": "French", "fra": "French", "fre": "French",
        "de": "German", "deu": "German", "ger": "German",
        "it": "Italian", "ita": "Italian",
        "pt": "Portuguese", "por": "Portuguese",
        "ru": "Russian", "rus": "Russian",
        "zh": "Chinese", "zho": "Chinese", "chi": "Chinese",
        "ko": "Korean", "kor": "Korean",
        "ar": "Arabic", "ara": "Arabic",
        "nl": "Dutch", "nld": "Dutch", "dut": "Dutch",
        "pl": "Polish", "pol": "Polish",
        "sv": "Swedish", "swe": "Swedish",
        "no": "Norwegian", "nor": "Norwegian",
        "da": "Danish", "dan": "Danish",
        "fi": "Finnish", "fin": "Finnish",
        "tr": "Turkish", "tur": "Turkish",
        "th": "Thai", "tha": "Thai",
        "vi": "Vietnamese", "vie": "Vietnamese",
        "id": "Indonesian", "ind": "Indonesian",
        "ms": "Malay", "msa": "Malay", "may": "Malay",
        "hi": "Hindi", "hin": "Hindi",
        "he": "Hebrew", "heb": "Hebrew",
        "uk": "Ukrainian", "ukr": "Ukrainian",
        "cs": "Czech", "ces": "Czech", "cze": "Czech",
        "hu": "Hungarian", "hun": "Hungarian",
        "el": "Greek", "ell": "Greek", "gre": "Greek",
        "ro": "Romanian", "ron": "Romanian", "rum": "Romanian",
        "tl": "Filipino", "fil": "Filipino",
    ]

    private static let englishCodes: Set<String> = ["en", "eng", "english"]

    public var isEnglish: Bool {
        if let lang, Self.englishCodes.contains(lang.lowercased()) { return true }
        return title?.lowercased().contains("english") ?? false
    }

    /// A signs-and-songs track: the handful of lines a dub viewer still
    /// wants (on-screen text, opening lyrics) rather than a full
    /// translation. Release groups say so in the title as often as they set
    /// the forced flag, so both have to count.
    public var isSignsOnly: Bool {
        let name = title?.lowercased() ?? ""
        return isForced || name.contains("sign") || name.contains("song")
    }

    /// Which subtitle track a Sub/Dub toggle should land on, given what the
    /// file carries and whatever the viewer last picked by hand. `nil` means
    /// "leave `sid` where it is" — a release with nothing matching is not a
    /// reason to strip the subtitles already showing.
    ///
    /// mpv runs its own subtitle selection when a file is loaded, and
    /// nothing on the Sub/Dub path used to touch `sid` at all, so whatever
    /// that selection had settled on for one audio language stayed put when
    /// the audio changed under it: Sub after Dub kept the narrow signs
    /// track it had been left with.
    public static func preferredSubtitle(
        preferDub: Bool,
        tracks: [PlayerTrack],
        explicit: String?
    ) -> String? {
        // A pick made by hand outranks both rules, a deliberate Off
        // included, for as long as this file stays loaded.
        if let explicit, explicit == off || tracks.contains(where: { $0.id == explicit }) {
            return explicit
        }
        let english = tracks.filter(\.isEnglish)
        if preferDub {
            return (english.first(where: \.isSignsOnly) ?? tracks.first(where: \.isSignsOnly))?.id
        }
        return (english.first(where: { !$0.isSignsOnly }) ?? english.first)?.id
    }
}
