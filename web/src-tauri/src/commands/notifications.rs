//! Background poller that turns AniList's AIRING notification feed into
//! native macOS notifications. AniList already tells us when a show on the
//! user's list airs a new episode (the same feed `NotificationsView` shows in
//! the app), but nothing previously surfaced that outside the app window —
//! `tauri-plugin-notification` was initialized and never called.

use std::collections::HashMap;

use tauri_plugin_notification::NotificationExt;

const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(15 * 60);

pub async fn start_airing_notification_worker(app_handle: tauri::AppHandle, state: crate::state::AppState) {
    log::info!("Airing-notification worker started");
    loop {
        tokio::time::sleep(POLL_INTERVAL).await;
        if let Err(e) = poll_once(&app_handle, &state).await {
            log::warn!("Airing-notification poll failed: {}", e);
        }
    }
}

async fn poll_once(app_handle: &tauri::AppHandle, state: &crate::state::AppState) -> Result<(), String> {
    // No account, nothing to poll. Gate on the (now real) Settings toggle too.
    if !state.anilist_client.has_token() {
        return Ok(());
    }
    let notifications_enabled = state.config.read().await.general.notifications;
    if !notifications_enabled {
        return Ok(());
    }

    let mut vars = HashMap::new();
    vars.insert("page".to_string(), serde_json::json!(1));
    vars.insert("perPage".to_string(), serde_json::json!(20));
    // Never reset AniList's own unread counter from a silent background
    // poll — that's mark_notifications_read's job, triggered by the user
    // actually opening the Notifications tab.
    vars.insert("reset".to_string(), serde_json::json!(false));

    let result: serde_json::Value = state
        .anilist_client
        .execute(crate::anilist::queries::USER_NOTIFICATIONS_QUERY, vars)
        .await?;

    let notifications = result
        .get("Page")
        .and_then(|p| p.get("notifications"))
        .and_then(|n| n.as_array())
        .cloned()
        .unwrap_or_default();

    let airing: Vec<&serde_json::Value> = notifications
        .iter()
        .filter(|n| n.get("type").and_then(|t| t.as_str()) == Some("AIRING"))
        .collect();
    if airing.is_empty() {
        return Ok(());
    }

    let last_seen = state.config.read().await.general.last_seen_notification_id;
    let (to_notify, new_max_id) = select_new_airings(&airing, last_seen);

    if last_seen.is_none() {
        // First run ever: establish the baseline silently. Otherwise enabling
        // this feature (or a first launch after an update) would fire a
        // notification for every episode that's aired since the account
        // existed.
        log::info!("Airing-notification worker: seeding baseline id {:?}", new_max_id);
    } else {
        for n in &to_notify {
            let title = n
                .get("media")
                .and_then(|m| m.get("title"))
                .and_then(|t| {
                    t.get("english")
                        .and_then(|v| v.as_str())
                        .filter(|s| !s.is_empty())
                        .or_else(|| t.get("romaji").and_then(|v| v.as_str()))
                })
                .unwrap_or("A show you're watching")
                .to_string();
            let episode = n.get("episode").and_then(|e| e.as_i64());
            let body = match episode {
                Some(ep) => format!("Episode {} just aired", ep),
                None => "A new episode just aired".to_string(),
            };

            if let Err(e) = app_handle.notification().builder().title(title).body(body).show() {
                log::warn!("Failed to show airing notification: {}", e);
            }
        }
    }

    if let Some(new_max_id) = new_max_id {
        let mut cfg = state.config.write().await;
        if cfg.general.last_seen_notification_id.map(|s| new_max_id > s).unwrap_or(true) {
            cfg.general.last_seen_notification_id = Some(new_max_id);
            drop(cfg);
            let _ = state.save_config().await;
        }
    }

    Ok(())
}

/// Pure selection: which airing notifications are new since `last_seen`, and
/// the highest id seen this batch (to persist as the new watermark). Split
/// out from `poll_once` so the dedup/seeding logic is unit-testable without a
/// live AniList token or Tauri app handle.
fn select_new_airings<'a>(
    airing: &'a [&'a serde_json::Value],
    last_seen: Option<i64>,
) -> (Vec<&'a serde_json::Value>, Option<i64>) {
    let max_id = airing.iter().filter_map(|n| n.get("id").and_then(|i| i.as_i64())).max();
    let to_notify = match last_seen {
        None => vec![],
        Some(seen) => airing
            .iter()
            .filter(|n| n.get("id").and_then(|i| i.as_i64()).unwrap_or(0) > seen)
            .copied()
            .collect(),
    };
    (to_notify, max_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn airing_notif(id: i64, episode: i64, title: &str) -> serde_json::Value {
        json!({
            "id": id, "type": "AIRING", "episode": episode,
            "media": { "title": { "romaji": title, "english": null } }
        })
    }

    #[test]
    fn first_run_seeds_without_notifying() {
        let a = airing_notif(100, 5, "Show A");
        let b = airing_notif(101, 3, "Show B");
        let items = vec![&a, &b];
        let (to_notify, max_id) = select_new_airings(&items, None);
        assert!(to_notify.is_empty(), "first run must not notify anything");
        assert_eq!(max_id, Some(101));
    }

    #[test]
    fn only_ids_newer_than_watermark_notify() {
        let a = airing_notif(100, 5, "Old");
        let b = airing_notif(102, 3, "New1");
        let c = airing_notif(105, 1, "New2");
        let items = vec![&a, &b, &c];
        let (to_notify, max_id) = select_new_airings(&items, Some(100));
        let ids: Vec<i64> = to_notify.iter().map(|n| n["id"].as_i64().unwrap()).collect();
        assert_eq!(ids, vec![102, 105]);
        assert_eq!(max_id, Some(105));
    }

    #[test]
    fn nothing_new_notifies_nothing() {
        let a = airing_notif(100, 5, "Old");
        let items = vec![&a];
        let (to_notify, max_id) = select_new_airings(&items, Some(100));
        assert!(to_notify.is_empty());
        assert_eq!(max_id, Some(100));
    }
}
