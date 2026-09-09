# Product

<!-- impeccable:product-schema 1 -->

## Platform

native (macOS now; iOS is the stated goal of the Swift rewrite)

## Users

Anime/manga viewers with an AniList account who want to watch, read, and track without a browser. Public GitHub repo; 6.0.0 is the first packaged release of the Swift app, and everything published up to v5.8.0 is the retired Tauri build. The audience today is the developer on a MacBook; the iPhone build runs but is held back from the release, since installing it needs a sideloading tool on a computer and lasts a week on a free Apple ID. First-run clarity still matters because the repo is public.

## Product Purpose

Native Apple app (SwiftUI over a Rust engine through UniFFI, libmpv in-process) that streams and tracks anime/manga with full two-way AniList sync — progress, scores, and list status stay current automatically without manual bookkeeping.

## Positioning

Wraps libmpv (in-window, Anime4K upscaling, AniSkip) and a torrent-backed source (SubsPlease, AnimeTosho, Nyaa, SeaDex; streams while downloading) around AniList as the source of truth for library state — a native alternative to browser-based streaming sites, with automatic fallback across releases and zero hosted content.

## Operating Context

First run: theme/preference setup, AniList authorization (browser page, token pasted back), library load. Playback and episode browsing work without an AniList account; sync features require one. Core loops: Up Next (continue-watching queue + "Pick for me"), manga reader (3 modes, RTL/LTR), torrent downloads for offline episodes, 7-day airing schedule, customizable home layout, Handoff between Macs.

## Capabilities and Constraints

- macOS only today, built from source. iOS is declared in Package.swift but AnicatUI still depends on AppKit; that gap is the main open engineering item.
- No hosted content — scrapes public third-party sites / streams from torrent swarms; legal exposure is the user's own (see DISCLAIMER.md).
- Anime comes from torrents only. Manga comes from MangaDex with MangaKatana as fallback, both in the Rust engine. Light novels come from Lnori for official volumes and Syosetu for web novels; the remaining providers in `scraper/` are a someday item, not a current goal.
- Cinema (TMDB) has a catalog but no playback path in the Swift build yet.
- libmpv is the only player, rendered inside the window.
- Keyboard: command palette, shortcuts overlay, Escape dismissal hierarchy. The web app's spatial-navigation focus system was not ported.

## Brand Commitments

Name "Anicat" and existing app icon are established; no other visual identity (palette, type, component language) is confirmed as binding — open canvas for design work.

## Evidence on Hand

- `README.md`, `ARCHITECTURE.md`, `CLAUDE.md` — architecture and command reference.
- `assets/branding/logo.png`, `assets/branding/dashboard.png` — existing logo and a real dashboard screenshot.
- `assets/branding/icon.icns` — the app icon.
- No user testimonials, case studies, or usage metrics on hand — do not fabricate any.

## Product Principles

- AniList is the single source of truth for progress/state; UI never lets local state drift from it silently.
- Playback should get out of the way fast (recent perf work: cut waits between play press and first frame, cut fixed waits on torrent resolve).
- Provider failures should fall through automatically rather than surfacing dead ends to the user.
- First-run and onboarding matter now that distribution is public, not just personal.

## Accessibility & Inclusion

No confirmed requirement beyond normal desktop-app baseline. Keyboard navigation exists through the command palette and shortcuts; full focus traversal was not ported from the web app.
