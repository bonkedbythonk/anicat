//! Light novel volumes kept on disk, for reading and for exporting with no
//! network.
//!
//! Separate from `reader::offline` because the two store different things: a
//! manga chapter is a directory of page images the reader hands to an image
//! view, and a volume is prose. They share the registry table
//! (`offline_chapters`, discriminated by `kind`) so that one size cap, one
//! eviction order and one Storage card in Settings cover both.
//!
//! **One file per volume, not per chapter.** A volume is the unit the user
//! downloads -- picking 16 chapters one at a time to take a book on a trip is
//! not a feature -- and it is the unit an EPUB is built from, so keeping the
//! whole thing in one JSON document means an export is a read and a build with
//! nothing to reassemble.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub struct NovelLibrary {
    root: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredNovelChapter {
    pub title: String,
    pub url: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredNovelVolume {
    /// The series, so an exported file can be named something a device
    /// library can tell apart. Defaulted for volumes stored before it was
    /// recorded, whose files are already on disk.
    #[serde(default)]
    pub series: String,
    pub title: String,
    #[serde(default)]
    pub author: String,
    pub source_url: String,
    pub chapters: Vec<StoredNovelChapter>,
}

impl StoredNovelVolume {
    /// Chapters that actually carry prose. The first entries of a volume are
    /// the cover and the colour inserts, which are images this does not carry.
    pub fn readable_chapters(&self) -> usize {
        self.chapters.iter().filter(|c| !c.text.trim().is_empty()).count()
    }

    /// What the book is called once it leaves the app. "Volume 2" alone says
    /// nothing in a library of fifty books, and the volume label is all the
    /// source's table of contents gives.
    pub fn full_title(&self) -> String {
        if self.series.is_empty() || self.title.contains(&self.series) {
            self.title.clone()
        } else {
            format!("{} - {}", self.series, self.title)
        }
    }
}

impl NovelLibrary {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Where one volume lives. Grouped by title, so deleting a title's
    /// downloads is a directory removal rather than a scan, and named by a
    /// hash of the volume URL for the same reason the manga side is: the id is
    /// a URL and cannot be a path component.
    pub fn volume_path(&self, catalog: &str, catalog_id: i64, volume_id: &str) -> PathBuf {
        self.root
            .join(catalog)
            .join(catalog_id.to_string())
            .join(format!("{:016x}.json", stable_hash(volume_id)))
    }

    /// Writes the volume, replacing any earlier copy. Returns its size on disk.
    pub fn store(
        &self,
        catalog: &str,
        catalog_id: i64,
        volume_id: &str,
        volume: &StoredNovelVolume,
    ) -> Result<u64, String> {
        let path = self.volume_path(catalog, catalog_id, volume_id);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec(volume).map_err(|e| e.to_string())?;
        std::fs::write(&path, &json).map_err(|e| e.to_string())?;
        Ok(json.len() as u64)
    }

    /// The stored volume, or `None` when it was never downloaded or the file
    /// has been removed underneath us. A half-written or unreadable file reads
    /// as not downloaded rather than as a book with holes in it.
    pub fn load(&self, catalog: &str, catalog_id: i64, volume_id: &str) -> Option<StoredNovelVolume> {
        let bytes = std::fs::read(self.volume_path(catalog, catalog_id, volume_id)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn delete(&self, catalog: &str, catalog_id: i64, volume_id: &str) -> Result<(), String> {
        let path = self.volume_path(catalog, catalog_id, volume_id);
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Total bytes held, for the shared size cap.
    pub fn size_bytes(&self) -> u64 {
        fn walk(dir: &std::path::Path) -> u64 {
            let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
            entries
                .flatten()
                .map(|entry| match entry.file_type() {
                    Ok(kind) if kind.is_dir() => walk(&entry.path()),
                    Ok(_) => entry.metadata().map(|m| m.len()).unwrap_or(0),
                    Err(_) => 0,
                })
                .sum()
        }
        walk(&self.root)
    }
}

/// FNV-1a. Not for security: it only has to be stable across runs and not
/// collide in practice over the handful of volumes one library holds.
fn stable_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in value.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn volume() -> StoredNovelVolume {
        StoredNovelVolume {
            series: "A Series".into(),
            title: "Vol. 1".into(),
            author: "Someone".into(),
            source_url: "https://lnori.com/book/12020/x".into(),
            chapters: vec![
                StoredNovelChapter { title: "Color Inserts".into(), url: "#page02".into(), text: String::new() },
                StoredNovelChapter { title: "Chapter 1".into(), url: "#page05".into(), text: "Prose.".into() },
            ],
        }
    }

    #[test]
    fn a_stored_volume_reads_back_as_it_went_in() {
        let dir = std::env::temp_dir().join(format!("anicat-novel-{}", std::process::id()));
        let library = NovelLibrary::new(dir.clone());
        library.store("AniList", 1, "https://lnori.com/book/12020/x", &volume()).unwrap();

        let back = library.load("AniList", 1, "https://lnori.com/book/12020/x").unwrap();
        assert_eq!(back.chapters.len(), 2);
        assert_eq!(back.readable_chapters(), 1);
        assert!(library.size_bytes() > 0);

        library.delete("AniList", 1, "https://lnori.com/book/12020/x").unwrap();
        assert_eq!(back.full_title(), "A Series - Vol. 1");
        assert!(library.load("AniList", 1, "https://lnori.com/book/12020/x").is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn deleting_something_that_was_never_downloaded_is_not_an_error() {
        let library = NovelLibrary::new(std::env::temp_dir().join("anicat-novel-absent"));
        assert!(library.delete("AniList", 9, "nothing").is_ok());
    }
}
