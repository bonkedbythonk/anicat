use discord_rich_presence::{DiscordIpc, DiscordIpcClient, activity, activity::ActivityType};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct DiscordClient {
    inner: Arc<Mutex<Option<DiscordIpcClient>>>,
}

impl DiscordClient {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(None)),
        }
    }

    pub fn connect(&self) {
        let mut guard = match self.inner.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if guard.is_some() {
            return;
        }
        let mut client = match DiscordIpcClient::new("1514749046542303443") {
            Ok(c) => c,
            Err(e) => {
                log::warn!("Failed to create Discord IPC client: {}", e);
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

    #[allow(clippy::too_many_arguments)] // mirrors the Discord activity fields
    pub fn set_presence(&self, title: &str, episode: i64, episode_title: &str, total_episodes: i64, pos: i64, duration: i64, paused: bool) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let mut state_str = if episode_title.is_empty() {
                    format!("Episode {}", episode)
                } else {
                    episode_title.to_string()
                };
                if paused {
                    state_str = format!("{} (Paused)", state_str);
                }

                let mut act = activity::Activity::new()
                    .activity_type(ActivityType::Watching)
                    .details(title)
                    .state(&state_str)
                    .assets(
                        activity::Assets::new()
                            .large_image("anicat")
                            .large_text(title),
                    )
                    .party(
                        activity::Party::new()
                            .size([episode as i32, total_episodes as i32]),
                    );

                if paused {
                    // Attach an explicit empty timestamps object. If we omit
                    // the field entirely, Discord keeps the previous activity's
                    // running timer; sending an empty object clears it, so a
                    // paused presence shows no clock at all.
                    act = act.timestamps(activity::Timestamps::new());
                } else if duration > 0 && pos < duration {
                    // Playing: show time remaining via an end timestamp.
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs() as i64;
                    let end_time = now + (duration - pos);
                    act = act.timestamps(activity::Timestamps::new().end(end_time));
                }

                let _ = client.set_activity(act);
            }
        }
    }

    pub fn clear_presence(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let _ = client.clear_activity();
            }
        }
    }
}
