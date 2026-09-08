# How Anicat got here

Anicat has been rewritten from the ground up three times in four months. Each
rewrite threw away the previous UI layer and kept the idea: one place to find,
play and track anime, with AniList as the source of truth.

Every date below comes from the commit that made the change. The repository
has three grafted root commits, so `git log` from the current branch alone
does not reach the beginning -- `git log --all --reverse` does.

## The terminal, May 2026

**2026-05-02** · `b2b0c5ec` *Initial import of Anicat media CLI*

A Python command-line tool: inquirer keybindings, playback handed to IINA,
an ASCII-art banner in the generated config. Built on the foundations of
[Viu](https://github.com/viu-media/viu) and refined for macOS -- the first
README said so outright.

The Viu lineage was cut loose three weeks later, **2026-05-21** in
`fa033faa` *remove viu legacy code and optimize architecture*.

## The web dashboard, May 2026

**2026-05-13** · `e4151030` *Add FastAPI dashboard*

A browser UI over the same Python core: FastAPI serving a Next.js frontend.
The terminal tool stayed underneath it.

## The packaged desktop app, June 2026

**2026-06-05** · `c3b3ae9c`

CI for macOS and Windows, mpv bundled rather than assumed, an installer
instead of a checkout. The first version anyone could be handed rather than
told how to build. Linux support was added and removed the same day.

## Tauri, June 2026 -- v4.0.0

**2026-06-10** · `5193aa48` *rewrite: scaffold Tauri v2 + Vite + React + Rust backend*

The first full rewrite. Next.js gave way to Vite (a 968ms build), the
monolithic Python sidecar to Rust commands over Tauri IPC, React Context to
Zustand. Scraping was isolated into a Python microservice with a 60s idle
timeout rather than living in the app.

The Python CLI package that started it all was deleted a fortnight later,
**2026-06-23** in `018ec861`, at v5.1.4.

Releases ran from **v5.5.1** (2026-07-17) to **v5.8.0** (2026-08-23). Five
major versions in four months is why the number is as high as it is: the
count belongs to the project, not to any one of its shapes.

## Native, September 2026 -- v6.0.0

**2026-09-03** · `1e43d969` *feat(core): headless Rust engine behind a UniFFI bridge*

The second full rewrite and the current one. Everything that decides what to
play and where it comes from moved into a headless Rust crate that knows
nothing about a UI; SwiftUI and AppKit draw it, with libmpv in-process rather
than driven over IPC.

**2026-09-05** · `7f30f65a` and `ab063a6f` removed `web/` and the Python
scraper, and `legacy/tauri` was tagged so the old app stays reachable.

Cinema mode (films and TV from TMDB), an iPhone target, and reading progress
for manga followed over the days after.
