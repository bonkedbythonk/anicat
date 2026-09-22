# Privacy

What Anicat sends, to whom, and what it keeps. There is no analytics, no
telemetry, no crash reporting and no account of its own. Everything below is
verifiable in the source: the hosts are literals in `core/src/` and
`AnicatApple/Sources/`.

## What leaves your machine, and when

**Always, when you use the feature**

| To | When | What they see |
|---|---|---|
| AniList (`graphql.anilist.co`) | Browsing, searching, and every list or progress change when signed in | Your IP, the queries, and your OAuth token once connected |
| TMDB, through Anicat's proxy (`anicat-tmdb.anicat.workers.dev`, a Cloudflare Worker) or directly with a key of your own | Films and TV browsing, searching and detail pages | Your IP and the titles you look at. The proxy holds the API key and adds no tracking; Cloudflare's edge logs the request like any CDN |
| Torrent indexes: `nyaa.si`, `subsplease.org`, `feed.animetosho.org` and `storage.animetosho.org`, `releases.moe` (SeaDex), `api.knaben.org` and `apibay.org` (films and TV) | Pressing Play on anime, a film or an episode | Your IP and the title searched for |
| Public trackers (`nyaa.tracker.wf`, `open.stealth.si`, `tracker.opentrackr.org`, `exodus.desync.com`, `tracker.torrent.eu.org`) and the BitTorrent DHT | Every play that comes from a torrent | Your IP and the info-hash of what you are downloading. Every other peer in that swarm sees the same. Anicat never uploads and opens no listening port |
| MangaDex (`api.mangadex.org`, `uploads.mangadex.org`, MangaDex@Home nodes) and MangaKatana (`mangakatana.com`) | Reading manga | Your IP and the chapters you open. MangaDex also receives the load report its network requires |
| Syosetu (`ncode.syosetu.com`) | Reading a pasted web novel | Your IP and the chapters you open |
| Lnori (`lnori.com`, `cdn.lnori.com`, `img.lnori.com`) | Only after Settings > Advanced > Light Novel Sources is switched on | Your IP and the volumes you open |
| AniSkip (`api.aniskip.com`), Jikan (`api.jikan.moe`), AniZip (`api.ani.zip`) | Playing anime: intro and outro timestamps, a missing MyAnimeList id, episode titles | Your IP and the title's id |
| GitHub (`api.github.com`) | Once a day at most, on launch, to see whether a newer release exists | Your IP and `Anicat/<version>` as the User-Agent. Nothing else |
| Anicat's release mirror (`anicat-releases.anicat.workers.dev`, a Cloudflare Worker) | Only when GitHub does not answer that check, or the installer cannot download from GitHub | The same: your IP and the version. It holds the app's own builds and nothing about you |

**Only when you turn it on**

| Setting | To | What they see |
|---|---|---|
| Settings > Sharing > Discord Rich Presence | Discord, over its local socket on this machine | In "Title" mode: the title, episode or chapter, cover art and an AniList or TMDB link, shown to everyone who can see your Discord profile. In "Private" mode: only "Watching anime" or "Reading manga" and the time |
| Settings > Sharing > Allow Other Devices | Everything on your local network, via Bonjour | This Mac's device name and that Anicat is running. A paired iPhone can then control playback and stream through the Mac |
| Handoff (macOS, between your own devices signed into the same Apple ID) | Apple's Handoff relay | The title, episode and position, so another of your Macs can offer to continue it |

## What stays on your machine

- `~/Library/Application Support/Anicat/registry.sqlite`: watch history,
  per-episode resume positions, provider slugs, local library, per-title
  preferences.
- `~/Library/Application Support/Anicat/config.json`: your AniList token,
  file mode 0600 (owner-only). The Keychain is the fallback store.
- `~/Library/Application Support/Anicat/torrent-streams/`: the stream cache,
  size-capped, evicted oldest first.
- `~/Library/Caches/`: catalog snapshots, safe to delete at any time.
- `~/Library/Logs/Anicat/anicat.log`: the log, rotated per launch, three
  kept. It names titles, releases and hosts. Nothing sends it anywhere; the
  "Copy Debug Report" button in Settings puts it on your clipboard for you to
  paste into a bug report if you choose.
- Watched titles are offered to Spotlight through Handoff activities, on
  this machine only.

## What Anicat does not do

- No analytics, telemetry or crash reporting to anyone, including the
  developer.
- No account, no server of the developer's, nothing hosted. The TMDB proxy
  forwards catalog requests and holds the key; it stores nothing about you.
- No uploading to torrent swarms, no listening port, no UPnP.

## Questions

Open an issue on the repository. Security matters go through GitHub's
private advisory form; see [SECURITY.md](SECURITY.md).
