//! Chapters kept on disk, for reading with no network.
//!
//! The pages a chapter is made of are ordinary image URLs, so "offline" here
//! is exactly that: fetch them once, write them in order, and hand the reader
//! `file://` URLs instead of remote ones. Nothing else about reading changes,
//! which is the point -- the reader has no idea where a page came from.
//!
//! **Files are named by position, not by source.** A page's URL carries a
//! MangaDex hash or a MangaKatana path, neither of which sorts and neither of
//! which survives the provider re-issuing it; the page's index in the chapter
//! is the only stable thing about it, and reading order is the only thing
//! this has to preserve.
//!
//! **A chapter's directory is named by a hash of its id.** MangaKatana's ids
//! are URLs -- slashes and all -- so they cannot be path components, and hex
//! of the whole id runs past what a filename may hold. The registry row keeps
//! the real id; this only has to be stable and collision-free in practice.

use std::path::{Path, PathBuf};

use futures_util::StreamExt;

/// How many pages are fetched at once.
///
/// Four rather than "all of them": a chapter is 20-60 images from one host,
/// and MangaDex asks in its own documentation that clients not open a
/// connection per page. It is also the number the torrent side settled on for
/// indexer queries, for the same reason -- past it, servers start refusing.
const PAGE_CONCURRENCY: usize = 4;

pub struct OfflineLibrary {
    root: PathBuf,
    http: reqwest::Client,
}

/// What one stored chapter's pages are, in reading order.
pub struct StoredChapter {
    pub dir: PathBuf,
    pub pages: Vec<PathBuf>,
    pub bytes: u64,
}

impl OfflineLibrary {
    pub fn new(root: PathBuf, http: reqwest::Client) -> Self {
        Self { root, http }
    }

    /// Where one chapter lives. Grouped by title so deleting a title's
    /// downloads is a directory removal rather than a scan.
    pub fn chapter_dir(&self, catalog: &str, catalog_id: i64, chapter_id: &str) -> PathBuf {
        self.root
            .join(catalog)
            .join(catalog_id.to_string())
            .join(format!("{:016x}", stable_hash(chapter_id)))
    }

    /// Fetches every page and writes it in order. Returns what was stored.
    ///
    /// A partial download is removed rather than left: half a chapter reads
    /// as a chapter that ends early, and there is nothing on the page to say
    /// otherwise.
    pub async fn download(
        &self,
        catalog: &str,
        catalog_id: i64,
        chapter_id: &str,
        page_urls: &[String],
    ) -> Result<StoredChapter, String> {
        if page_urls.is_empty() {
            return Err("chapter has no pages".to_string());
        }
        let dir = self.chapter_dir(catalog, catalog_id, chapter_id);
        std::fs::create_dir_all(&dir).map_err(|e| format!("offline: {e}"))?;

        let results: Vec<Result<(usize, PathBuf, u64), String>> =
            // Cloned rather than borrowed: a closure holding `&String` is
            // not general enough over lifetimes for the async runtime this is
            // polled on, and a page URL is a short string.
            futures_util::stream::iter(page_urls.iter().cloned().enumerate().map(|(index, url)| {
                let http = self.http.clone();
                let dir = dir.clone();
                async move {
                    let bytes = http
                        .get(&url)
                        .send()
                        .await
                        .map_err(|e| format!("page {}: {e}", index + 1))?
                        .error_for_status()
                        .map_err(|e| format!("page {}: {e}", index + 1))?
                        .bytes()
                        .await
                        .map_err(|e| format!("page {}: {e}", index + 1))?;
                    let path = dir.join(format!("{:04}.{}", index, extension_of(&url)));
                    std::fs::write(&path, &bytes).map_err(|e| format!("page {}: {e}", index + 1))?;
                    Ok((index, path, bytes.len() as u64))
                }
            }))
            .buffer_unordered(PAGE_CONCURRENCY)
            .collect()
            .await;

        let mut stored: Vec<(usize, PathBuf, u64)> = Vec::with_capacity(results.len());
        for result in results {
            match result {
                Ok(page) => stored.push(page),
                Err(msg) => {
                    let _ = std::fs::remove_dir_all(&dir);
                    return Err(msg);
                }
            }
        }
        stored.sort_by_key(|(index, _, _)| *index);
        let bytes = stored.iter().map(|(_, _, size)| size).sum();
        Ok(StoredChapter {
            dir,
            pages: stored.into_iter().map(|(_, path, _)| path).collect(),
            bytes,
        })
    }

    /// The stored pages of a chapter, in reading order, or `None` when it is
    /// not downloaded. Read from the directory rather than from a stored
    /// list: a file deleted underneath us -- a cache clean, a sync tool --
    /// must read as "not downloaded", not as a chapter with holes.
    pub fn pages(&self, catalog: &str, catalog_id: i64, chapter_id: &str) -> Option<Vec<PathBuf>> {
        let dir = self.chapter_dir(catalog, catalog_id, chapter_id);
        let mut pages: Vec<PathBuf> = std::fs::read_dir(&dir)
            .ok()?
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.is_file())
            .collect();
        if pages.is_empty() {
            return None;
        }
        // The names are zero-padded indices, so lexical order is page order.
        pages.sort();
        Some(pages)
    }

    pub fn delete(&self, catalog: &str, catalog_id: i64, chapter_id: &str) -> Result<(), String> {
        let dir = self.chapter_dir(catalog, catalog_id, chapter_id);
        match std::fs::remove_dir_all(&dir) {
            Ok(()) => Ok(()),
            // Already gone is the state the caller wanted.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("offline: {e}")),
        }
    }

    /// Bytes on disk under the whole library.
    pub fn size_bytes(&self) -> u64 {
        directory_size(&self.root)
    }
}

/// The file extension to store a page under, from its URL.
///
/// Kept because the decoder picks its path by extension and a `.img` for a
/// JPEG makes it guess; anything unrecognisable becomes `jpg`, which is what
/// both providers serve when they serve anything.
fn extension_of(url: &str) -> String {
    let tail = url.split('?').next().unwrap_or(url);
    let ext = tail.rsplit('.').next().unwrap_or("");
    match ext.to_ascii_lowercase().as_str() {
        "png" => "png".to_string(),
        "webp" => "webp".to_string(),
        "gif" => "gif".to_string(),
        "jpeg" | "jpg" => "jpg".to_string(),
        _ => "jpg".to_string(),
    }
}

/// FNV-1a. Not for security -- for turning an id that may contain slashes
/// into sixteen hex characters that cannot.
fn stable_hash(value: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in value.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

fn directory_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .filter_map(|entry| entry.ok())
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => directory_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_chapter_id_with_slashes_is_still_one_directory() {
        let lib = OfflineLibrary::new(PathBuf::from("/tmp/anicat-offline-test"), reqwest::Client::new());
        // MangaKatana's ids are URLs; MangaDex's are UUIDs.
        let katana = lib.chapter_dir("anilist", 21, "https://mangakatana.com/manga/x/c12");
        let dex = lib.chapter_dir("anilist", 21, "0a1b2c3d-4e5f-6789-abcd-ef0123456789");
        assert_eq!(katana.components().count(), dex.components().count());
        assert!(katana.file_name().unwrap().to_string_lossy().len() == 16);
        assert_ne!(katana, dex);
    }

    #[test]
    fn pages_sort_by_position_not_by_name_from_the_url() {
        let dir = std::env::temp_dir().join("anicat-offline-order-test");
        let _ = std::fs::remove_dir_all(&dir);
        let lib = OfflineLibrary::new(dir.clone(), reqwest::Client::new());
        let chapter = lib.chapter_dir("anilist", 1, "c1");
        std::fs::create_dir_all(&chapter).unwrap();
        // Written out of order, and with names that would sort wrongly if the
        // index were not zero-padded.
        for index in [10, 2, 1, 0] {
            std::fs::write(chapter.join(format!("{index:04}.jpg")), b"x").unwrap();
        }
        let pages = lib.pages("anilist", 1, "c1").unwrap();
        let names: Vec<String> = pages
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        assert_eq!(names, vec!["0000.jpg", "0001.jpg", "0002.jpg", "0010.jpg"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_undownloaded_chapter_has_no_pages_and_deleting_it_is_not_an_error() {
        let dir = std::env::temp_dir().join("anicat-offline-missing-test");
        let lib = OfflineLibrary::new(dir, reqwest::Client::new());
        assert!(lib.pages("anilist", 1, "nope").is_none());
        assert!(lib.delete("anilist", 1, "nope").is_ok());
    }

    #[test]
    fn a_page_keeps_an_extension_its_decoder_recognises() {
        assert_eq!(extension_of("https://x/y/1.png"), "png");
        assert_eq!(extension_of("https://x/y/1.JPEG"), "jpg");
        assert_eq!(extension_of("https://x/y/1.webp?token=abc"), "webp");
        // MangaDex serves plenty of pages with no extension at all.
        assert_eq!(extension_of("https://x/data/abc123"), "jpg");
    }
}
