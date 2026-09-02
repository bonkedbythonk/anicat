use serde_json::Value;
use tauri::State;
use std::path::PathBuf;

use crate::state::AppState;

#[tauri::command]
pub async fn search_novels(
    state: State<'_, AppState>,
    query: String,
    provider: Option<String>,
) -> Result<Value, String> {
    let prov = provider.unwrap_or_else(|| {
        state.config.try_read()
            .map(|c| c.general.novel_provider.clone())
            .unwrap_or_else(|_| "ranobedb".to_string())
    });
    state.scraper_manager.search_novels(&query, &prov).await
}

#[tauri::command]
pub async fn get_novel_details(
    state: State<'_, AppState>,
    slug: String,
    provider: Option<String>,
) -> Result<Value, String> {
    let prov = provider.unwrap_or_else(|| {
        state.config.try_read()
            .map(|c| c.general.novel_provider.clone())
            .unwrap_or_else(|_| "ranobedb".to_string())
    });
    state.scraper_manager.get_novel(&slug, &prov).await
}

#[tauri::command]
pub async fn get_novel_toc(
    state: State<'_, AppState>,
    volume_url: String,
    title: Option<String>,
) -> Result<Value, String> {
    state.scraper_manager.get_novel_toc(&volume_url, title.as_deref()).await
}

#[tauri::command]
pub async fn get_novel_chapter(
    state: State<'_, AppState>,
    slug: String,
    chapter: String,
    url: Option<String>,
) -> Result<Value, String> {
    state.scraper_manager.get_novel_chapter(&slug, &chapter, url.as_deref()).await
}

#[tauri::command]
pub async fn get_ereader_presets(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    state.scraper_manager.get_novel_presets().await
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn download_novel_epub(
    state: State<'_, AppState>,
    slug: String,
    volume_id: Option<i64>,
    volume_title: Option<String>,
    target_width: Option<u32>,
    target_height: Option<u32>,
    grayscale: Option<bool>,
    jpeg_quality: Option<u32>,
    split_spreads: Option<bool>,
    output_dir: Option<String>,
) -> Result<Value, String> {
    let cfg = state.config.read().await;

    // Resolve output folder
    let out_dir = output_dir.or_else(|| {
        if !cfg.general.downloads_path.is_empty() {
            Some(cfg.general.downloads_path.clone())
        } else {
            dirs::download_dir().map(|p| p.to_string_lossy().to_string())
        }
    }).unwrap_or_else(|| "~/Downloads".to_string());

    let payload = serde_json::json!({
        "slug": slug,
        "volume_id": volume_id,
        "volume_title": volume_title,
        "target_width": target_width.unwrap_or(cfg.general.ereader_width),
        "target_height": target_height.unwrap_or(cfg.general.ereader_height),
        "grayscale": grayscale.unwrap_or(cfg.general.ereader_grayscale),
        "jpeg_quality": jpeg_quality.unwrap_or(cfg.general.ereader_quality),
        "split_spreads": split_spreads.unwrap_or(cfg.general.ereader_split_spreads),
        "output_dir": out_dir,
    });

    state.scraper_manager.build_novel_epub(payload).await
}

#[tauri::command]
pub async fn open_novel_file(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err(format!("File does not exist: {}", path));
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to reveal in Finder: {}", e))?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", path))
            .spawn()
            .map_err(|e| format!("Failed to open in Explorer: {}", e))?;
    }

    #[cfg(target_os = "linux")]
    {
        if let Some(parent) = p.parent() {
            std::process::Command::new("xdg-open")
                .arg(parent)
                .spawn()
                .map_err(|e| format!("Failed to open folder: {}", e))?;
        }
    }

    Ok(())
}
