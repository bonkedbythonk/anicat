//! Anicat's engine, as a headless library.
//!
//! Everything that decides *what to play and where it comes from* lives here:
//! the catalog clients, the torrent indexer race, the pack layout parser, the
//! librqbit session, the MangaDex reader and the registry. Nothing here knows
//! there is a UI, and nothing here links a UI framework — the Apple app talks
//! to it across the UniFFI boundary declared at the bottom of this file.

pub mod catalog;
pub mod db;
pub mod discord;
pub mod media;
pub mod reader;
pub mod torrent;

// Public for server/, which calls the engine as a Rust crate rather than
// through bindings; private, every type it returns was unnameable there.
pub mod ffi;

pub use db::{Catalog, Registry};
pub use media::MediaKey;

uniffi::setup_scaffolding!();
