## Anicat 6.0.1

The first update to the native app. Cinema mode is the headline: it no longer
asks for an AniList account, and it is on by default in every build.

### Cinema without AniList

Setup now asks where to start before anything else. Pick Cinema and the
AniList step is skipped: films and series come from TMDB, your watchlist is
kept on the device, and nothing in that mode needs an account. The "AniList is
down" banner stays in Anime mode, where it belongs. Anyone who later switches
to Anime can still connect from Settings.

### Player

- Closing the player now refreshes Resume and Up Next straight away, and the
  audio stops with the picture instead of running a second past the close.
- Resume works after a rewatch of an earlier episode, and Undo on "marked
  watched" restores the progress and the list status, not one less.
- The resolving card names the release it is connecting to and counts the
  seconds; a play from the Up Next shelf gets next, previous, auto-next and
  the preload like a play from the page does.
- The mini-player picture no longer sticks at 320x180 in the corner of the
  full player after a resize while playing.
- Ambient glow: a subtitle line no longer collapses the bottom band on a
  2.35:1 film, the controls sit inside the lit bars instead of painting a
  scrim over them, and sideways mode no longer draws a black band over the
  top and bottom of the turned picture.
- Anime4K runs on anime only. Films and series and any source of 1440 rows
  or more play untouched; the player says so once when it opens them.
- The keyboard backlight goes dark with the controls and stays lit while
  they are up.
- The episode still shown while a stream connects dissolves into a soft
  colour wash instead of sitting as a small card in the middle of the screen.
- The info menu fits the window, Sub/Dub can go and find a release in the
  other language, and an unaired episode is no longer somewhere Next can go.
- Closing the player can no longer leave a second, frozen window behind.

### Cinema

- Genre, year and sort filters live in Search, and the grid pages itself.
- The phone's Films and TV segment loads, and three ways a stream could
  report the wrong thing are fixed.
- The TMDB proxy is the default in every build, so cinema mode cannot go
  missing from a build that forgot to set it.

### Feedback

Warmer sounds, and haptics that actually fire on a trackpad.

### Installer

The one-line installer refuses macOS 14 and older up front (the app needs
macOS 15), falls back to `~/Applications` on an account that cannot write
`/Applications`, and no longer depends on the GitHub API's per-address
request limit to find the download.

### Upgrading from 5.x

Same as 6.0.0: the AniList token carries over from `config.toml`, do not use
the 5.x app's own Update button, and `scripts/cleanup_legacy_macos.sh` lists
the retired app's leftover data.
