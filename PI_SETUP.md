# Running anicat headless on a Raspberry Pi

This sets up the `anicat-server` binary (a headless build of the same backend the
desktop app uses — no window, no mpv) on a Raspberry Pi 3, reachable from your
phone anywhere via Tailscale. It serves the mobile PWA and the same
`/mobile-api/*` surface the desktop app exposes on your home LAN today, just
running continuously instead of only while the desktop app is open.

This is Stage 1: one shared AniList account (the one already in your desktop
`config.toml`), reachable only from devices you invite into your Tailscale
network. Per-friend AniList logins are a later stage — until then, treat this
as "my own account, reachable from my own devices anywhere."

**Build strategy note:** the Pi 3 has only 1GB of RAM, and `cargo build
--release` for this crate (Tauri's Linux bindings + axum + tokio + rusqlite +
librqbit) routinely uses well over that during codegen — it would very likely
OOM-kill partway through a native on-device build, or at best thrash swap on
a slow SD card for hours. So the binary gets **built on your Mac inside an
arm64 Docker container** (a real native aarch64 compile, not a fragile
cross-compilation — Docker's `--platform linux/arm64` runs actual
aarch64 code, natively if your Mac is Apple Silicon, emulated via Docker's
built-in QEMU integration if it's Intel) and then copied to the Pi, which
only ever *runs* the finished binary.

## What you need

- A Raspberry Pi 3 (1GB RAM — fine for running the server, not for compiling it)
- Raspberry Pi OS **64-bit** (Lite is fine — no desktop environment needed).
  Flash it with Raspberry Pi Imager, enable SSH in the imager's settings so
  you don't need a monitor/keyboard. Double-check you picked the 64-bit
  image specifically — the Pi 3's SoC supports AArch64, but Imager's default
  for older Pi models can still be the 32-bit legacy image, which won't run
  an aarch64 binary.
- Docker Desktop installed on your Mac
- SSH access to the Pi from your Mac
- A [Tailscale](https://tailscale.com) account (free tier is enough)

## 1. Build anicat-server on your Mac, targeting the Pi's OS

Raspberry Pi OS is Debian-based (current releases track Debian 12
"bookworm"), so building inside a matching Debian container keeps the
compiled binary's glibc version compatible with what's actually on the Pi.
From the repo root on your **Mac**:

```bash
mkdir -p /tmp/anicat-docker-output
docker run --rm --platform linux/arm64 \
  -v "$PWD":/work:ro \
  -v /tmp/anicat-docker-output:/output \
  -w /build \
  rust:1-bookworm \
  bash -c "
    set -e
    apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev git &&
    git clone /work /build &&
    cd web/src-tauri &&
    touch resources/mpv resources/mpv.exe &&
    mkdir -p resources/lib && touch resources/lib/.gitkeep &&
    mkdir -p resources/scraper-bin/anicat-scraper/_internal &&
    touch resources/scraper-bin/anicat-scraper/anicat-scraper &&
    touch resources/scraper-bin/anicat-scraper/_internal/.gitkeep &&
    cargo build --release --bin anicat-server &&
    cp target/release/anicat-server /output/
  "
```

The `libwebkit2gtk`/`libgtk-3`/`libsoup` dev packages are needed to *compile*
`anicat-server` even though it never opens a window — the Tauri crate it
shares code with links against them unconditionally on Linux. Because this
is a real native-arm64 container (not a cross-compiler), `apt-get install`
just works normally here — no cross-architecture package wrangling.

Two things worth knowing about that command:
- It clones your repo into a **fresh location inside the container**
  (`git clone /work /build`) rather than building directly against your
  bind-mounted working copy. Your Mac's `web/src-tauri/resources/` has
  gitignored, locally-built artifacts for the *desktop* app (mpv binaries,
  bundled libs — some of which are symlinks into your Homebrew install, e.g.
  `resources/lib/Python`, which can never resolve inside any container).
  Building from a clean clone sidesteps all of that, and also means this
  matches exactly what happens when the Pi later does its own `git clone`.
- The `touch`/`mkdir` lines **stub those same gitignored resource paths**
  with empty placeholders — Tauri's build script validates that every
  resource glob in `tauri.conf.json` has at least one match, even though
  `anicat-server` doesn't bundle or use any of them (no mpv, no bundled
  scraper binary — it uses the `uv`-managed source scraper instead). This is
  the identical stubbing trick this repo's own CI already uses for the same
  reason (see `.github/workflows/ci.yml`).

This will take a while the first time (pulling the image, compiling the full
dependency tree) — grab a coffee. Afterwards, the binary is at
`/tmp/anicat-docker-output/anicat-server` on your Mac. Subsequent builds
after pulling code changes reuse Cargo's incremental cache inside the
container's layer cache and are much faster, as long as you don't prune it.

Copy it to the Pi:

```bash
scp /tmp/anicat-docker-output/anicat-server pi@<pi-hostname>:/tmp/anicat-server
```

## 2. Runtime packages on the Pi

SSH into the Pi. It only needs the *runtime* shared libraries (no `-dev`
headers, no compiler — nothing gets built here), plus `uv` for the Python
scraper and `git` to pull the scraper source and future updates:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl \
  libwebkit2gtk-4.1-0 libgtk-3-0 libsoup-3.0-0 libjavascriptcoregtk-4.1-0
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"
```

## 3. Get the scraper + mobile PWA onto the Pi

The Rust binary is already built and copied over — you just need the Python
scraper source and the mobile PWA's static files. Easiest path: clone the
repo on the Pi for the scraper source (it's plain Python, fine to run
in-place), and copy the frontend build from your Mac:

```bash
sudo mkdir -p /opt/anicat
sudo chown $USER:$USER /opt/anicat
git clone <your-repo-url> /opt/anicat/src
sudo mkdir -p /opt/anicat/bin
sudo mv /tmp/anicat-server /opt/anicat/bin/anicat-server
sudo chmod +x /opt/anicat/bin/anicat-server
```

## 4. Set up the scraper

The scraper is a `uv`-managed Python project — no manual venv needed, `uv`
resolves one automatically the first time it runs:

```bash
cd /opt/anicat/src/scraper
uv sync
```

`nodriver` (one of the scraper's dependencies) drives a real headless
Chromium for some providers' Cloudflare bypass — worth keeping an eye on
memory if you notice the Pi getting tight at runtime (see the swap note in
step 7), since that's a heavier process than the rest of the scraper.

## 5. Build the mobile PWA static files

From your **Mac** (much faster than the Pi either way, but doubly true here
since we're not building anything else on the Pi at all now):

```bash
cd web
npm install
npm run build
```

Then copy the built `dist/` folder to the Pi:

```bash
scp -r dist pi@<pi-hostname>:/opt/anicat/mobile-dist
```

## 6. The user the service runs as

The service runs as the default `pi` login user — no dedicated service user.
That means its config lives at `/home/pi/.config/anicat/` (`config.toml`,
`registry.db`), and everything under `/opt/anicat` should be owned by `pi`
(the `chown $USER:$USER` in step 3 already did that if you SSH'd in as `pi`).

A dedicated locked-down user would be slightly tidier permission-wise, but
running as `pi` keeps debugging simple (the interactive shell sees exactly
what the service sees) and matches the actual deployment.

## 7. A safety-margin swap file

Nothing here needs to *build* on the Pi anymore, but at runtime the Rust
server + the Python scraper (which can spin up a real headless Chromium via
`nodriver` for some providers) share 1GB of RAM. A small permanent swap file
costs nothing when unused and avoids an OOM-kill if things get briefly tight:

```bash
sudo apt install -y dphys-swapfile
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
sudo systemctl restart dphys-swapfile
```

## 8. systemd service

```bash
sudo tee /etc/systemd/system/anicat.service > /dev/null <<'EOF'
[Unit]
Description=anicat headless server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=pi
Environment=HOME=/home/pi
Environment=ANICAT_SCRAPER_PYTHON=/home/pi/.local/bin/uv
Environment=ANICAT_SCRAPER_SCRIPT=/opt/anicat/src/scraper/main.py
Environment=ANICAT_MOBILE_DIST=/opt/anicat/mobile-dist
ExecStart=/opt/anicat/bin/anicat-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now anicat.service
```

`ANICAT_SCRAPER_PYTHON` is the *full path* to `uv` — the systemd service
doesn't get your login shell's PATH, so a bare `uv` wouldn't resolve
(`~/.local/bin` is only added by the shell profile).

Check it's actually up:

```bash
sudo systemctl status anicat.service
journalctl -u anicat.service -f    # live logs, Ctrl+C to stop watching
```

## 9. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Follow the printed login URL to add the Pi to your tailnet.

Find the Pi's Tailscale hostname / IP:

```bash
tailscale status
```

### 9a. Giving friends access — use node sharing, not tailnet members

Important: the Tailscale **free (Personal) plan caps a tailnet at 3 users**.
Inviting 7 friends as full tailnet *members* blows past that. The correct
(free, unlimited) way to hand out access to a single machine is **node
sharing** — and it's also safer, because a shared-in device can reach *only
the Pi*, never the rest of your devices:

1. Each friend makes their own free Tailscale account and installs the
   Tailscale app on their phone.
2. You: [admin console](https://login.tailscale.com/admin/machines) -> the Pi
   -> the "..." menu -> **Share...** -> copy the share link -> send it to that
   friend (one link per friend).
3. The friend opens the link, accepts, and enables the shared node in their
   Tailscale app. Their phone can now reach the Pi from anywhere.

If you already added the 7 friends as tailnet members, migrate them to shares
before you hit the 3-user cap.

### 9b. Recommended: serve over HTTPS with `tailscale serve`

The steps below reach the Pi over plain `http://…:13370`. Inside Tailscale
that traffic is already WireGuard-encrypted end to end, so this is not a
confidentiality problem — but a plain-HTTP origin is not a "secure context"
in the browser, which blocks PWA niceties (service worker, some device APIs)
and just looks less trustworthy. One command fixes it, with a real
auto-renewed TLS cert and a clean hostname, tailnet-only:

```bash
sudo tailscale serve --bg 13370
```

Your PWA URL then becomes `https://<pi-hostname>.<tailnet>.ts.net/mobile.html`
(see `tailscale serve status` for the exact name). Nothing else changes.

### 9c. Firewall: close the LAN path (applied)

`anicat-server` binds `0.0.0.0:13370`, so without a firewall it answers over
the Pi's LAN IP too, not only the Tailscale one. That means anything on the
home network — a guest phone, a neighbour who has the wifi password — can
reach `/proxy` and `/torrent-stream`, which are deliberately ungated (see the
router comment in `proxy/server.rs`), and pull video through the Pi without
ever meeting the PIN gate. It also puts that traffic on the household uplink.

`ufw` now restricts inbound traffic to SSH plus the `tailscale0` interface:

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow in on tailscale0
sudo ufw --force enable
```

Port 13370 is now unreachable from the LAN. It stays reachable over the
tailnet, and `tailscale serve` (9b) keeps working because it proxies from
loopback, which `ufw` permits by default. SSH is left open on purpose so
`scripts/deploy-pi.sh` still works over mDNS (`pi@anicatpi.local`) without
requiring the deploying machine to be on the tailnet.

`ufw` is enabled at boot, so this survives a restart.

**If you ever re-run this on a fresh Pi**, arm a dead-man switch before
enabling, so a mistake in the rules can't lock you out of a headless box:

```bash
sudo systemd-run --unit=ufw-panic --on-active=300 /usr/sbin/ufw --force disable
```

Then enable `ufw`, open a *fresh* SSH connection to prove it still works, and
cancel the timer with `sudo systemctl stop ufw-panic.timer`. If you get locked
out instead, wait five minutes and the firewall disables itself.

## 10. First connection

On your phone (with Tailscale running and connected to the same tailnet),
open a browser to:

```
http://<pi-tailscale-hostname>:13370/mobile.html
```

You should hit the same PIN gate the desktop app's LAN mode uses today — the
PIN is whatever's set in Settings → Phone Access on the desktop app (that
setting is stored in `config.toml`, which the Pi build reads from the same
place). From there, everything should work exactly like it does over your
home Wi-Fi today: browsing, search, streaming, manga — just reachable from
anywhere your phone has a signal.

This is single-user mode: everyone who has the PIN streams through your own
AniList account. If a friend wants their own AniList login and their own
separate watch progress instead, see "Adding a friend their own account"
below — flip that on before handing out access, since switching later
doesn't retroactively split up progress that was already recorded under your
account.

## 11. Adding a friend their own account (optional)

Each friend can have their own AniList login and their own watch
progress/lists, fully separate from yours and from each other's. This is
opt-in — skip this section entirely if everyone sharing your account is
fine.

On the **Pi**, create an account for each friend (their PIN can be anything
they'll remember — it's identity, not a security boundary; Tailscale is what
actually keeps strangers out):

```bash
/opt/anicat/bin/anicat-server add-user "Sam" 4821
```

Then turn on multi-user mode in `config.toml` (the service runs as `pi`, so
that's `/home/pi/.config/anicat/config.toml`):

```toml
[general]
multi_user = true
```

```bash
sudo systemctl restart anicat.service
```

Text or call each friend their PIN (out of band — not through anicat
itself). When they open the PWA, they'll see a "Who's watching?" screen
instead of the plain PIN box: they enter their name and PIN, then a
one-time "Connect AniList" step (opens AniList's login in their own phone
browser, same as the very first desktop setup) links their own account.
From then on their watch history, lists, and progress are entirely their
own — invisible to you and to any other friend.

Add more friends any time with the same `add-user` command — no restart
needed for that part, only the first time you flip `multi_user` on.

## 12. Daily maintenance timers

Two systemd timers keep an eye on the deployment. Install/update both from
your **Mac** (idempotent — rerun after editing anything in `scripts/pi/`):

```bash
bash scripts/pi/install-pi-timers.sh   # optional arg: pi hostname, default anicatpi.local
```

- **`anicat-smoke.timer`** — daily at 09:00 (±15 min jitter), runs the
  provider smoke test (`scraper/smoke_test.py`, shipped to the Pi by the
  install script). No push alerting (ntfy.sh iOS delivery proved unreliable
  and was dropped) — check results manually:
  `ssh pi@anicatpi.local 'journalctl -u anicat-smoke.service -n 20'`.
- **`anicat-backup.timer`** — daily at 04:30, snapshots `registry.db` (via
  sqlite's online backup API, safe against the live server) and `config.toml`
  from `/home/pi/.config/anicat/` into `/opt/anicat/backups/`, keeping the 14
  most recent of each. This protects against corruption and bad migrations,
  not SD-card death — occasionally pull the backups off the Pi:

  ```bash
  rsync -az pi@anicatpi.local:/opt/anicat/backups/ ~/anicat-pi-backups/
  ```

Check timer status on the Pi with
`systemctl list-timers 'anicat-*'` and last-run logs with
`journalctl -u anicat-smoke.service -u anicat-backup.service -n 50`.

## Updating later

Rebuild happens on your **Mac**, same command as the first build (step 1):

```bash
mkdir -p /tmp/anicat-docker-output
docker run --rm --platform linux/arm64 \
  -v "$PWD":/work:ro \
  -v /tmp/anicat-docker-output:/output \
  -w /build \
  rust:1-bookworm \
  bash -c "
    set -e
    apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev git &&
    git clone /work /build &&
    cd web/src-tauri &&
    touch resources/mpv resources/mpv.exe &&
    mkdir -p resources/lib && touch resources/lib/.gitkeep &&
    mkdir -p resources/scraper-bin/anicat-scraper/_internal &&
    touch resources/scraper-bin/anicat-scraper/anicat-scraper &&
    touch resources/scraper-bin/anicat-scraper/_internal/.gitkeep &&
    cargo build --release --bin anicat-server &&
    cp target/release/anicat-server /output/
  "
scp /tmp/anicat-docker-output/anicat-server pi@<pi-hostname>:/tmp/anicat-server
```

(Since this clones fresh each time rather than reusing your working copy,
make sure whatever you want deployed is actually committed first — an
uncommitted local change won't be in the clone.)

Then on the **Pi**:

```bash
sudo mv /tmp/anicat-server /opt/anicat/bin/anicat-server
sudo chmod +x /opt/anicat/bin/anicat-server
sudo systemctl restart anicat.service
```

If the scraper's Python source changed, also `git pull` inside
`/opt/anicat/src` on the Pi and re-run `uv sync` (step 4). If the frontend
changed, rebuild and re-copy `mobile-dist` (step 5) before restarting.

## Troubleshooting

- **Service won't start** — `journalctl -u anicat.service -n 50` for the
  actual error. Most common cause: `ANICAT_MOBILE_DIST` pointing at a folder
  that doesn't exist yet (step 5 wasn't done) or `/opt/anicat` not owned by
  `pi` (step 3's `chown`).
- **Scraper errors in the log** — SSH in as `pi` and run
  `cd /opt/anicat/src/scraper && uv run python main.py --port 9999` manually
  to see the real Python traceback (the service runs as the same user, so
  you're seeing exactly its environment).
- **Can't reach it from your phone** — confirm both the phone and the Pi show
  up in `tailscale status` / the admin console, and that you're using the
  Tailscale hostname (or its `100.x.x.x` IP), not the Pi's LAN IP — the LAN
  IP only works when your phone is on the same home Wi-Fi.
