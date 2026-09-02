# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Anime/manga viewers with an AniList account who want to watch, read, and track without a browser. Public GitHub distribution (macOS/Windows releases) — audience is unknown strangers downloading the app, not just the developer, so onboarding and clarity for first-time users matter.

## Product Purpose

Native desktop app (Tauri + React frontend, Python scraper sidecar, mpv playback) that streams and tracks anime/manga with full two-way AniList sync — progress, scores, and list status stay current automatically without manual bookkeeping.

## Positioning

Wraps mpv (external player, Anime4K upscaling, AniSkip) and a torrent-backed provider (SubsPlease API + Nyaa RSS, streams while downloading) around AniList as the source of truth for library state — a desktop-native alternative to browser-based streaming sites, with automatic provider fallback and zero hosted content.

## Operating Context

First run: theme/preference setup, AniList OAuth (browser redirect back into app), library load. Playback and episode browsing work without an AniList account; sync features require one. Core loops: Up Next (continue-watching queue + "Pick for me"), manga reader (3 modes, RTL/LTR), download queue (yt-dlp, background), 7-day airing schedule, customizable home layout.

## Capabilities and Constraints

- Desktop only (macOS DMG unsigned — requires quarantine-clear script; Windows exe, SmartScreen warning expected).
- No hosted content — scrapes public third-party sites / streams from torrent swarms; legal exposure is the user's own (see DISCLAIMER.md).
- One anime provider: `nyaa` (torrents). Every scraper-based anime provider has been retired — `anineko` is kept in-tree in case it returns, `mkissa`/allanime was removed outright. The Python sidecar now serves manga and light novels only.
- mpv is the primary player (Anime4K, AniSkip); desktop also has a builtin `<video>` HLS-remux path for formats WebKit can play directly.
- Keyboard-navigation focus system is an active, partially-complete effort (per project memory): MediaDetail/overlay done, manga view deferred.

## Brand Commitments

Name "Anicat" and existing app icon are established; no other visual identity (palette, type, component language) is confirmed as binding — open canvas for design work.

## Evidence on Hand

- `README.md`, `ARCHITECTURE.md`, `CLAUDE.md` — architecture and command reference.
- `assets/branding/logo.png`, `assets/branding/dashboard.png` — existing logo and a real dashboard screenshot.
- `web/src-tauri/icons/` — full app icon set (macOS/Windows sizes).
- No user testimonials, case studies, or usage metrics on hand — do not fabricate any.

## Product Principles

- AniList is the single source of truth for progress/state; UI never lets local state drift from it silently.
- Playback should get out of the way fast (recent perf work: cut waits between play press and first frame, cut fixed waits on torrent resolve).
- Provider failures should fall through automatically rather than surfacing dead ends to the user.
- First-run and onboarding matter now that distribution is public, not just personal.

## Accessibility & Inclusion

No confirmed requirement beyond normal desktop-app baseline. Keyboard navigation is an existing in-progress effort, not a newly established requirement.
