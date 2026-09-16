//! The one serial queue every progress and list write goes through.
//!
//! `record_progress` is a synchronous SQLite write and can stall as long as
//! SQLite does. On the Mac each playback tick used to spawn its own task,
//! and a stalled earlier tick finishing after a later one wrote the older
//! position last: the resume point went backwards. One task that awaits each
//! job before taking the next makes "last submitted" and "last written" the
//! same thing. List writes share the queue so a manual mark-watched and a
//! tick for the same episode land in the order they were asked for.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use anicat_core::ffi::{AnicatEngine, AnicatError, FfiCatalog};
use tokio::sync::{mpsc, oneshot};

use crate::error::{ApiError, ApiResult};

type Job = Box<dyn FnOnce(Arc<AnicatEngine>) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send>;

#[derive(Clone)]
pub struct Writer {
    tx: mpsc::UnboundedSender<Job>,
}

impl Writer {
    pub fn spawn(engine: Arc<AnicatEngine>) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<Job>();
        tokio::spawn(async move {
            while let Some(job) = rx.recv().await {
                job(engine.clone()).await;
            }
        });
        Self { tx }
    }

    /// Runs `f` on the queue after everything submitted before it, and
    /// hands back its result.
    pub async fn submit<T, F, Fut>(&self, f: F) -> ApiResult<T>
    where
        T: Send + 'static,
        F: FnOnce(Arc<AnicatEngine>) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, AnicatError>> + Send + 'static,
    {
        let (reply, answer) = oneshot::channel();
        let job: Job = Box::new(move |engine| {
            Box::pin(async move {
                let _ = reply.send(f(engine).await);
            })
        });
        self.tx
            .send(job)
            .map_err(|_| ApiError::internal("writer queue has shut down"))?;
        answer
            .await
            .map_err(|_| ApiError::internal("writer job was dropped"))?
            .map_err(ApiError::from)
    }

    /// Like `submit` for the engine's synchronous SQLite calls. They run on
    /// the blocking pool: called straight from the queue task they would
    /// hold a runtime worker for as long as SQLite stalls, and the HTTP
    /// handlers share those workers.
    pub async fn submit_blocking<T, F>(&self, f: F) -> ApiResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&AnicatEngine) -> Result<T, AnicatError> + Send + 'static,
    {
        self.submit(move |engine| async move {
            tokio::task::spawn_blocking(move || f(&engine))
                .await
                .map_err(|e| AnicatError::Internal { msg: e.to_string() })?
        })
        .await
    }

    #[allow(dead_code)] // the caller is wave 2's playback tick handler
    pub async fn record_progress(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        episode: i64,
        stop_time: i64,
        duration: i64,
    ) -> ApiResult<()> {
        self.submit_blocking(move |e| e.record_progress(catalog, catalog_id, episode, stop_time, duration))
            .await
    }

    pub async fn mark_episode_completed(&self, catalog: FfiCatalog, catalog_id: i64, episode: i64) -> ApiResult<()> {
        self.submit_blocking(move |e| e.mark_episode_completed(catalog, catalog_id, episode))
            .await
    }

    pub async fn update_list_entry(
        &self,
        catalog_id: i64,
        status: Option<String>,
        score: Option<f64>,
        progress: Option<i64>,
    ) -> ApiResult<()> {
        self.submit(move |e| async move { e.update_list_entry(catalog_id, status, score, progress).await })
            .await
    }

    pub async fn remove_from_list(&self, list_entry_id: i64) -> ApiResult<()> {
        self.submit(move |e| async move { e.remove_from_list(list_entry_id).await })
            .await
    }

    pub async fn set_cinema_list_status(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        status: Option<String>,
    ) -> ApiResult<()> {
        self.submit_blocking(move |e| e.set_cinema_list_status(catalog, catalog_id, status))
            .await
    }

    pub async fn record_title_track_preference(
        &self,
        catalog: FfiCatalog,
        catalog_id: i64,
        audio_lang: Option<String>,
        subtitle_lang: Option<String>,
        subtitle_title: Option<String>,
    ) -> ApiResult<()> {
        self.submit_blocking(move |e| {
            e.record_title_track_preference(catalog, catalog_id, audio_lang, subtitle_lang, subtitle_title)
        })
        .await
    }
}
