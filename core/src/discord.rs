//! Discord Rich Presence, ported from the Tauri app's `discord.rs` — same
//! Discord application id (its Developer Portal assets, including the
//! `anicat` image key, are registered against it).
//!
//! Every IPC call runs on one worker thread, and callers only replace the
//! wanted presence under a mutex. The Swift side used to make the socket
//! writes itself on its progress queue: a presence set once a second, a
//! write that could stall for as long as Discord's read side did, and a
//! stall that held the SQLite progress write queued behind it. Discord also
//! rate-limits `SET_ACTIVITY` to five per twenty seconds and drops the rest,
//! so a per-second writer was mostly writing into the void. The worker
//! coalesces to the latest wanted state, skips a write that would change
//! nothing on the profile, spaces the ones it does make, and reconnects when
//! Discord was started (or restarted) after Anicat.
//!
//! Playback and reading hold separate slots. The manga reader can be open
//! over a mini-player episode, and a single slot let closing the reader wipe
//! the episode's presence. Playback wins while both are set; clearing it
//! brings the reading presence back.
//!
//! A paused episode shows nothing, Spotify's convention. Discord has no
//! paused state: an activity sent without timestamps gets a clock of
//! Discord's own, counting up from when it was set, so "E3 · Paused" read
//! as still watching and its timer kept climbing for as long as the pause.

use discord_rich_presence::{
    activity::{self, ActivityType, StatusDisplayType},
    DiscordIpc, DiscordIpcClient,
};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DISCORD_APP_ID: &str = "1514749046542303443";
/// The image key registered in the Developer Portal.
const APP_IMAGE_KEY: &str = "anicat";

/// Five writes per twenty seconds is Discord's limit; spacing at the limit
/// means the latest state is never more than this late, and never dropped.
const MIN_WRITE_GAP: Duration = Duration::from_secs(4);
/// Between connect attempts while Discord is not running. Each attempt is a
/// directory scan for the socket, cheap, but it logs.
const RECONNECT_INTERVAL: Duration = Duration::from_secs(15);
/// How far the computed start time may drift before it counts as a change.
/// The caller reports whole seconds a second apart, so a playing episode's
/// start wobbles by up to a second every tick; a J/L seek moves it by 30.
const TIMESTAMP_TOLERANCE_MS: i64 = 5_000;

/// Discord rejects the whole activity, silently, when a text field is
/// shorter than 2 or longer than 128 characters.
const TEXT_MIN_CHARS: usize = 2;
const TEXT_MAX_CHARS: usize = 128;
const IMAGE_URL_MAX_CHARS: usize = 256;
const BUTTON_LABEL_MAX_CHARS: usize = 32;
const BUTTON_URL_MAX_CHARS: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscordPresenceSource {
    Playback,
    Reading,
}

/// How much the profile shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscordPresenceDetail {
    /// Title, episode or chapter, cover, and a link to the catalog page.
    Full,
    /// "Watching anime" and the clock; no title, cover or link. The title
    /// is visible to everyone on the friends list and in every shared
    /// server, which is not something everyone wants for everything.
    Private,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DiscordPresence {
    pub source: DiscordPresenceSource,
    /// With its article where English wants one: "anime", "a film",
    /// "a TV series", "manga", "a light novel". Only the private line uses it.
    pub medium: String,
    pub title: String,
    /// The second line: "E3 · Killing Magic", "Ch. 42", "1999 · 2h 19m".
    /// Empty shows the title alone.
    pub subtitle: String,
    /// Shown when hovering the cover, for what the second line leaves out
    /// ("Frieren · Episode 3 of 28"). `None` shows the title.
    pub hover_text: Option<String>,
    pub cover_url: Option<String>,
    pub link_label: Option<String>,
    pub link_url: Option<String>,
    /// Playback: position in the file. Reading: seconds since the chapter
    /// opened, shown as elapsed time.
    pub position_secs: i64,
    /// Zero or less when unknown, or for reading: no countdown is shown.
    pub duration_secs: i64,
    /// Playback only: withdraws the presence while set, letting a reading
    /// presence underneath show.
    pub paused: bool,
}

/// What would actually be sent, with times made absolute. Compared against
/// the last one written to decide whether a write is needed at all.
#[derive(Debug, Clone, PartialEq)]
struct Payload {
    watching: bool,
    details: String,
    state: Option<String>,
    large_image: String,
    large_text: Option<String>,
    with_small_image: bool,
    button: Option<(String, String)>,
    start_ms: Option<i64>,
    end_ms: Option<i64>,
    title_in_status: bool,
}

fn text(s: &str) -> Option<String> {
    let trimmed = s.trim();
    let count = trimmed.chars().count();
    if count < TEXT_MIN_CHARS {
        return None;
    }
    if count > TEXT_MAX_CHARS {
        let cut: String = trimmed.chars().take(TEXT_MAX_CHARS - 3).collect();
        return Some(format!("{}...", cut.trim_end()));
    }
    Some(trimmed.to_string())
}

fn https_url(url: Option<&str>, max_chars: usize) -> Option<String> {
    let url = url?.trim();
    (url.starts_with("https://") && url.chars().count() <= max_chars).then(|| url.to_string())
}

fn build_payload(p: &DiscordPresence, detail: DiscordPresenceDetail, now_ms: i64) -> Payload {
    let watching = p.source == DiscordPresenceSource::Playback;
    let verb = if watching { "Watching" } else { "Reading" };

    let (start_ms, end_ms) = if p.position_secs < 0 {
        (None, None)
    } else if p.duration_secs > 0 && p.position_secs < p.duration_secs {
        let start = now_ms - p.position_secs * 1000;
        (Some(start), Some(start + p.duration_secs * 1000))
    } else if p.duration_secs <= 0 {
        (Some(now_ms - p.position_secs * 1000), None)
    } else {
        (None, None)
    };

    let private_line =
        || text(&format!("{verb} {}", p.medium)).unwrap_or_else(|| format!("{verb} on Anicat"));

    match detail {
        DiscordPresenceDetail::Private => Payload {
            watching,
            details: private_line(),
            state: None,
            large_image: APP_IMAGE_KEY.to_string(),
            large_text: None,
            with_small_image: false,
            button: None,
            start_ms,
            end_ms,
            title_in_status: false,
        },
        DiscordPresenceDetail::Full => {
            let details = text(&p.title).unwrap_or_else(private_line);
            let state = text(&p.subtitle);
            let cover = https_url(p.cover_url.as_deref(), IMAGE_URL_MAX_CHARS);
            let button = match (
                p.link_label.as_deref().and_then(text),
                https_url(p.link_url.as_deref(), BUTTON_URL_MAX_CHARS),
            ) {
                (Some(label), Some(url)) if label.chars().count() <= BUTTON_LABEL_MAX_CHARS => {
                    Some((label, url))
                }
                _ => None,
            };
            Payload {
                watching,
                with_small_image: cover.is_some(),
                large_image: cover.unwrap_or_else(|| APP_IMAGE_KEY.to_string()),
                large_text: p.hover_text.as_deref().and_then(text).or_else(|| text(&p.title)),
                details,
                state,
                button,
                start_ms,
                end_ms,
                title_in_status: true,
            }
        }
    }
}

fn close_in_time(a: Option<i64>, b: Option<i64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => (a - b).abs() <= TIMESTAMP_TOLERANCE_MS,
        _ => false,
    }
}

/// Whether writing `next` would change what the profile shows after `last`.
fn same_on_profile(last: &Option<Payload>, next: &Option<Payload>) -> bool {
    match (last, next) {
        (None, None) => true,
        (Some(a), Some(b)) => {
            close_in_time(a.start_ms, b.start_ms)
                && close_in_time(a.end_ms, b.end_ms)
                && Payload {
                    start_ms: None,
                    end_ms: None,
                    ..a.clone()
                } == Payload {
                    start_ms: None,
                    end_ms: None,
                    ..b.clone()
                }
        }
        _ => false,
    }
}

fn to_activity(p: &Payload) -> activity::Activity<'_> {
    let mut assets = activity::Assets::new().large_image(p.large_image.as_str());
    if let Some(large_text) = &p.large_text {
        assets = assets.large_text(large_text.as_str());
    }
    if p.with_small_image {
        assets = assets.small_image(APP_IMAGE_KEY).small_text("Anicat");
    }

    // Omitting the field kept the previous activity's timer running. An
    // empty object does not stop the clock either: Discord then counts up
    // from when the activity was set, which is why a pause withdraws the
    // activity instead of sending one without times.
    let mut timestamps = activity::Timestamps::new();
    if let Some(start) = p.start_ms {
        timestamps = timestamps.start(start);
    }
    if let Some(end) = p.end_ms {
        timestamps = timestamps.end(end);
    }

    let mut act = activity::Activity::new()
        .activity_type(if p.watching {
            ActivityType::Watching
        } else {
            ActivityType::Playing
        })
        .status_display_type(if p.title_in_status {
            StatusDisplayType::Details
        } else {
            StatusDisplayType::Name
        })
        .details(p.details.as_str())
        .assets(assets)
        .timestamps(timestamps);
    if let Some(state) = &p.state {
        act = act.state(state.as_str());
    }
    if let Some((label, url)) = &p.button {
        act = act.buttons(vec![activity::Button::new(label.as_str(), url.as_str())]);
    }
    act
}

/// Which presence the profile should show: playing beats reading, and a
/// paused episode steps aside for the reader or, with none open, for nothing.
fn shown(state: &State) -> Option<(DiscordPresence, i64)> {
    state
        .playback
        .clone()
        .filter(|(p, _)| !p.paused)
        .or_else(|| state.reading.clone())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

struct State {
    enabled: bool,
    /// Held here rather than on each presence, so a change in Settings
    /// rewrites what is showing now instead of waiting for the next tick.
    detail: DiscordPresenceDetail,
    worker_started: bool,
    /// Each with the wall-clock moment it was reported, so a write delayed
    /// by the spacing still computes the start time the caller meant.
    playback: Option<(DiscordPresence, i64)>,
    reading: Option<(DiscordPresence, i64)>,
    dirty: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            enabled: false,
            detail: DiscordPresenceDetail::Full,
            worker_started: false,
            playback: None,
            reading: None,
            dirty: false,
        }
    }
}

struct Shared {
    state: Mutex<State>,
    wake: Condvar,
}

pub struct DiscordClient {
    shared: Arc<Shared>,
}

impl Default for DiscordClient {
    fn default() -> Self {
        Self::new()
    }
}

impl DiscordClient {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State::default()),
                wake: Condvar::new(),
            }),
        }
    }

    fn change(&self, f: impl FnOnce(&mut State)) {
        let Ok(mut state) = self.shared.state.lock() else {
            return;
        };
        f(&mut state);
        state.dirty = true;
        if state.enabled && !state.worker_started {
            state.worker_started = true;
            let shared = Arc::clone(&self.shared);
            let spawned = std::thread::Builder::new()
                .name("discord-presence".into())
                .spawn(move || run_worker(shared));
            if let Err(e) = spawned {
                log::warn!("[discord] worker thread not started: {e}");
                state.worker_started = false;
            }
        }
        self.shared.wake.notify_one();
    }

    /// Turns presence on. Connecting happens on the worker, and again every
    /// `RECONNECT_INTERVAL` for as long as there is something to show and
    /// Discord is not there to show it.
    pub fn connect(&self) {
        // No Discord client runs on iOS and no socket would ever appear;
        // enabled there, the worker would scan for one every 15s for as
        // long as the app ran.
        if cfg!(target_os = "ios") {
            return;
        }
        self.change(|s| s.enabled = true);
    }

    /// Turns presence off: the worker clears the activity and closes the
    /// socket, which is what makes it disappear from the profile.
    pub fn disconnect(&self) {
        self.change(|s| s.enabled = false);
    }

    pub fn set_detail(&self, detail: DiscordPresenceDetail) {
        self.change(|s| s.detail = detail);
    }

    pub fn update(&self, presence: DiscordPresence) {
        let at = now_ms();
        self.change(|s| match presence.source {
            DiscordPresenceSource::Playback => s.playback = Some((presence, at)),
            DiscordPresenceSource::Reading => s.reading = Some((presence, at)),
        });
    }

    pub fn clear(&self, source: DiscordPresenceSource) {
        self.change(|s| match source {
            DiscordPresenceSource::Playback => s.playback = None,
            DiscordPresenceSource::Reading => s.reading = None,
        });
    }
}

fn send(
    client: &mut DiscordIpcClient,
    payload: &Option<Payload>,
) -> Result<(), discord_rich_presence::error::Error> {
    match payload {
        Some(p) => client.set_activity(to_activity(p))?,
        None => client.clear_activity()?,
    }
    // Discord answers every command, and the crate never reads the answer.
    // Unread, the replies fill the socket buffer until Discord's own write
    // blocks and it stops reading ours, which is the stall the Swift side
    // used to eat on every tick. Reading it also surfaces a rejected
    // activity, which Discord otherwise drops without a trace.
    let (_, reply) = client.recv()?;
    if reply.get("evt").and_then(|e| e.as_str()) == Some("ERROR") {
        log::warn!(
            "[discord] activity rejected: {}",
            reply.get("data").unwrap_or(&reply)
        );
    }
    Ok(())
}

fn run_worker(shared: Arc<Shared>) {
    let mut client: Option<DiscordIpcClient> = None;
    let mut last_sent: Option<Payload> = None;
    let mut last_write: Option<Instant> = None;
    let mut next_connect = Instant::now();
    let mut reported_unavailable = false;
    let mut retry_at: Option<Instant> = None;

    loop {
        let (enabled, detail, wanted) = {
            let Ok(mut state) = shared.state.lock() else {
                return;
            };
            while !state.dirty {
                match retry_at {
                    Some(at) => {
                        let now = Instant::now();
                        if now >= at {
                            break;
                        }
                        let Ok((next, _)) = shared.wake.wait_timeout(state, at - now) else {
                            return;
                        };
                        state = next;
                    }
                    None => {
                        let Ok(next) = shared.wake.wait(state) else {
                            return;
                        };
                        state = next;
                    }
                }
            }
            state.dirty = false;
            retry_at = None;
            (state.enabled, state.detail, shown(&state))
        };

        if !enabled {
            if let Some(mut c) = client.take() {
                let _ = send(&mut c, &None);
                let _ = c.close();
            }
            last_sent = None;
            continue;
        }

        let desired = wanted.map(|(p, at)| build_payload(&p, detail, at));
        if client.is_some() && same_on_profile(&last_sent, &desired) {
            continue;
        }
        if client.is_none() && desired.is_none() {
            last_sent = None;
            continue;
        }

        let now = Instant::now();
        if client.is_none() {
            if now < next_connect {
                retry_at = Some(next_connect);
                continue;
            }
            let mut fresh = DiscordIpcClient::new(DISCORD_APP_ID);
            match fresh.connect() {
                Ok(()) => {
                    log::info!("[discord] connected");
                    reported_unavailable = false;
                    client = Some(fresh);
                    last_sent = None;
                }
                Err(e) => {
                    if !reported_unavailable {
                        log::info!(
                            "[discord] not connected ({e}); retrying every {}s",
                            RECONNECT_INTERVAL.as_secs()
                        );
                        reported_unavailable = true;
                    }
                    next_connect = now + RECONNECT_INTERVAL;
                    retry_at = Some(next_connect);
                    continue;
                }
            }
        }

        if let Some(last) = last_write {
            if now < last + MIN_WRITE_GAP {
                retry_at = Some(last + MIN_WRITE_GAP);
                continue;
            }
        }

        let Some(c) = client.as_mut() else { continue };
        last_write = Some(Instant::now());
        match send(c, &desired) {
            Ok(()) => last_sent = desired,
            Err(e) => {
                // Discord quit or restarted under us. Retry soon rather than
                // at the full interval: a restarted Discord is usually back
                // within seconds.
                log::info!("[discord] write failed ({e}); reconnecting");
                client = None;
                last_sent = None;
                next_connect = Instant::now() + MIN_WRITE_GAP;
                retry_at = Some(next_connect);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn episode() -> DiscordPresence {
        DiscordPresence {
            source: DiscordPresenceSource::Playback,
            medium: "anime".into(),
            title: "Frieren".into(),
            subtitle: "E3 · Killing Magic".into(),
            hover_text: Some("Frieren · Episode 3 of 28".into()),
            cover_url: Some(
                "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx154587.jpg".into(),
            ),
            link_label: Some("View on AniList".into()),
            link_url: Some("https://anilist.co/anime/154587".into()),
            position_secs: 120,
            duration_secs: 1440,
            paused: false,
        }
    }

    const NOW: i64 = 1_800_000_000_000;

    /// Puts a real activity on whatever account the local Discord is signed
    /// into, for 90 seconds, and prints Discord's reply. The reply is the only
    /// place a rejected cover shows up: an https `large_image` Discord will
    /// not proxy comes back as an error or with the asset missing, and the
    /// profile just draws no picture.
    #[test]
    #[ignore]
    fn live_cover_url_as_large_image() {
        let mut client = DiscordIpcClient::new(DISCORD_APP_ID);
        client.connect().expect("Discord is not running");
        let cover = "https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx154587-qQTzQnEJJ3oB.jpg";
        let payload = build_payload(
            &DiscordPresence { cover_url: Some(cover.into()), ..episode() },
            DiscordPresenceDetail::Full,
            now_ms(),
        );
        client.set_activity(to_activity(&payload)).expect("write failed");
        let (_, reply) = client.recv().expect("no reply");
        println!("reply: {reply}");
        std::thread::sleep(Duration::from_secs(90));
        let _ = client.clear_activity();
        let _ = client.recv();
        let _ = client.close();
    }

    #[test]
    fn full_shows_title_cover_link_and_a_countdown() {
        let p = build_payload(&episode(), DiscordPresenceDetail::Full, NOW);
        assert_eq!(p.details, "Frieren");
        assert_eq!(p.state.as_deref(), Some("E3 · Killing Magic"));
        assert_eq!(p.large_text.as_deref(), Some("Frieren · Episode 3 of 28"));
        assert!(p.large_image.starts_with("https://"));
        assert!(p.with_small_image);
        assert_eq!(
            p.button.as_ref().map(|b| b.0.as_str()),
            Some("View on AniList")
        );
        assert_eq!(p.start_ms, Some(NOW - 120_000));
        assert_eq!(p.end_ms, Some(NOW - 120_000 + 1_440_000));
    }

    #[test]
    fn private_names_only_the_medium() {
        let p = build_payload(&episode(), DiscordPresenceDetail::Private, NOW);
        assert_eq!(p.details, "Watching anime");
        assert_eq!(p.state, None);
        assert_eq!(p.large_image, APP_IMAGE_KEY);
        assert_eq!(p.large_text, None);
        assert_eq!(p.button, None);
        assert!(!p.title_in_status);
    }

    #[test]
    fn a_paused_episode_shows_nothing_or_the_reader_under_it() {
        let paused = DiscordPresence {
            paused: true,
            ..episode()
        };
        let chapter = DiscordPresence {
            source: DiscordPresenceSource::Reading,
            ..episode()
        };
        let mut state = State {
            playback: Some((paused, NOW)),
            ..State::default()
        };
        assert_eq!(shown(&state), None);
        state.reading = Some((chapter.clone(), NOW));
        assert_eq!(shown(&state), Some((chapter, NOW)));
        state.playback = Some((episode(), NOW));
        assert_eq!(shown(&state), Some((episode(), NOW)));
    }

    #[test]
    fn reading_counts_up_with_no_end() {
        let p = build_payload(
            &DiscordPresence {
                source: DiscordPresenceSource::Reading,
                subtitle: "Chapter 42".into(),
                position_secs: 30,
                duration_secs: 0,
                ..episode()
            },
            DiscordPresenceDetail::Full,
            NOW,
        );
        assert!(!p.watching);
        assert_eq!((p.start_ms, p.end_ms), (Some(NOW - 30_000), None));
    }

    #[test]
    fn rejects_what_discord_would_refuse() {
        let long = "x".repeat(300);
        let p = build_payload(
            &DiscordPresence {
                title: long.clone(),
                subtitle: "1".into(),
                cover_url: Some("http://insecure.example/cover.jpg".into()),
                link_label: Some("A label far longer than thirty-two characters".into()),
                ..episode()
            },
            DiscordPresenceDetail::Full,
            NOW,
        );
        assert_eq!(p.details.chars().count(), TEXT_MAX_CHARS);
        assert_eq!(p.state, None);
        assert_eq!(p.large_image, APP_IMAGE_KEY);
        assert!(!p.with_small_image);
        assert_eq!(p.button, None);
    }

    #[test]
    fn a_tick_a_second_later_is_not_a_change() {
        let a = build_payload(&episode(), DiscordPresenceDetail::Full, NOW);
        let b = build_payload(
            &DiscordPresence {
                position_secs: 121,
                ..episode()
            },
            DiscordPresenceDetail::Full,
            NOW + 1_400,
        );
        assert!(same_on_profile(&Some(a), &Some(b)));
    }

    #[test]
    fn a_seek_and_a_new_episode_are_changes() {
        let a = Some(build_payload(&episode(), DiscordPresenceDetail::Full, NOW));
        let seek = build_payload(
            &DiscordPresence {
                position_secs: 150,
                ..episode()
            },
            DiscordPresenceDetail::Full,
            NOW,
        );
        let next = build_payload(
            &DiscordPresence {
                subtitle: "E4 · Frieren the Mage".into(),
                ..episode()
            },
            DiscordPresenceDetail::Full,
            NOW,
        );
        assert!(!same_on_profile(&a, &Some(seek)));
        assert!(!same_on_profile(&a, &Some(next)));
        assert!(!same_on_profile(&a, &None));
    }
}
