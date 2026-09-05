//! Discord Rich Presence, ported from the Tauri app's `discord.rs` — same
//! Discord application id (its Developer Portal assets, including the
//! `anicat` large-image key, are registered against it) and the same set of
//! calls, just relocated here so the native build gets presence too instead
//! of skipping it entirely.

use discord_rich_presence::{activity, activity::ActivityType, DiscordIpc, DiscordIpcClient};
use std::sync::Mutex;

const DISCORD_APP_ID: &str = "1514749046542303443";

pub struct DiscordClient {
    inner: Mutex<Option<DiscordIpcClient>>,
}

impl Default for DiscordClient {
    fn default() -> Self {
        Self::new()
    }
}

impl DiscordClient {
    pub fn new() -> Self {
        Self { inner: Mutex::new(None) }
    }

    pub fn connect(&self) {
        let Ok(mut guard) = self.inner.lock() else { return };
        if guard.is_some() {
            return;
        }
        let mut client = match DiscordIpcClient::new(DISCORD_APP_ID) {
            Ok(c) => c,
            Err(e) => {
                log::warn!("Failed to create Discord IPC client: {e}");
                return;
            }
        };
        if client.connect().is_err() {
            log::warn!("Failed to connect to Discord (is Discord running?)");
            return;
        }
        *guard = Some(client);
    }

    pub fn disconnect(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let _ = client.clear_activity();
                let _ = client.close();
            }
            *inner = None;
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn set_presence(
        &self,
        title: &str,
        episode: i64,
        episode_title: &str,
        total_episodes: i64,
        pos: i64,
        duration: i64,
        paused: bool,
    ) {
        let Ok(mut inner) = self.inner.lock() else { return };
        let Some(ref mut client) = *inner else { return };

        let mut state_str = if episode_title.is_empty() { format!("Episode {episode}") } else { episode_title.to_string() };
        if paused {
            state_str = format!("{state_str} (Paused)");
        }

        let mut act = activity::Activity::new()
            .activity_type(ActivityType::Watching)
            .details(title)
            .state(&state_str)
            .assets(activity::Assets::new().large_image("anicat").large_text(title))
            .party(activity::Party::new().size([episode as i32, total_episodes as i32]));

        if paused {
            // An explicit empty timestamps object clears Discord's running
            // clock; omitting the field entirely leaves the previous
            // activity's timer ticking under a "Paused" label.
            act = act.timestamps(activity::Timestamps::new());
        } else if duration > 0 && pos < duration {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
            act = act.timestamps(activity::Timestamps::new().end(now + (duration - pos)));
        }

        let _ = client.set_activity(act);
    }

    pub fn clear_presence(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let _ = client.clear_activity();
            }
        }
    }
}
