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
        drop(guard);
        self.set_browsing();
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

    pub fn set_browsing(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let act = activity::Activity::new()
                    .activity_type(ActivityType::Watching)
                    .state("Anicat")
                    .details("Browsing");
                let _ = client.set_activity(act);
            }
        }
    }

    pub fn set_presence(&self, title: &str, episode: i64, episode_title: &str, total_episodes: i64) {
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(ref mut client) = *inner {
                let state = if episode_title.is_empty() {
                    format!("Episode {}", episode)
                } else {
                    episode_title.to_string()
                };

                let act = activity::Activity::new()
                    .activity_type(ActivityType::Watching)
                    .details(title)
                    .state(&state)
                    .assets(
                        activity::Assets::new()
                            .large_image("anicat")
                            .large_text(title),
                    )
                    .party(
                        activity::Party::new()
                            .size([episode as i32, total_episodes as i32]),
                    );

                let _ = client.set_activity(act);
            }
        }
    }

    pub fn clear_presence(&self) {
        self.set_browsing();
    }
}
