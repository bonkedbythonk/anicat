# Anicat's release mirror

Every path a user or the app takes to a new version runs through GitHub:
the install command fetches `scripts/install_macos.sh` from the repository,
the app's update check reads the releases API, and the assets are release
attachments. One takedown notice against the repository removes all of it
at once, and the people who installed the app learn about it from a 404.
This worker is the second path: the same `anicat.workers.dev` subdomain the
TMDB proxy already uses, a KV namespace holding `latest.json`, `SHA256SUMS`
and the installer, and optionally an R2 bucket holding the binaries.

`UpdateChecker` asks GitHub first and this worker when GitHub answers with
anything but a release. `install_macos.sh` and `install_windows.ps1` do the
same for the download. Until the worker is deployed every one of those
fallbacks finds nothing and the caller carries on exactly as before, so
shipping the code ahead of the deploy costs nothing.

Once it is deployed and a release has been published into it, add this to
the main README's Install section (it is deliberately not there yet: a
public instruction pointing at an undeployed worker is a dead end for the
exact person who needs it). It works with the repository gone:

```bash
curl -fsSL https://anicat-releases.anicat.workers.dev/install.sh | bash
```

## Deploy, once

```bash
cd services/release-mirror
npx wrangler login
npx wrangler kv namespace create RELEASES   # paste the id into wrangler.toml
npx wrangler deploy
```

`deploy` prints the URL. It is expected to be
`https://anicat-releases.anicat.workers.dev`; if the account's subdomain is
different, set `ANICAT_RELEASE_MIRROR` when running `publish-release.sh`
and change the constant in `UpdateChecker.swift` and both installers.

To mirror the binaries as well (the part that survives a takedown), enable
R2 on the account, create the bucket, and uncomment the `[[r2_buckets]]`
block in `wrangler.toml`:

```bash
npx wrangler r2 bucket create anicat-releases
npx wrangler deploy
```

`publish-release.sh` uploads the assets whenever that block is present.

## What a release writes

`publish-release.sh`, after `gh release create`:

- `latest.json`: `{"version","tag","published_at","page","assets":{name:{"sha256","size","url"}}}`
- `SHA256SUMS`: the same file attached to the release
- `install.sh`: the current `scripts/install_macos.sh`
- with R2: every asset, under its release file name

The Windows zip is attached to the release by CI some minutes after the Mac
side publishes, so it is not in `latest.json` and not in R2; its
`/download/` route redirects to GitHub. Mirroring it too would need a
Cloudflare API token in the repository secrets.

## Test

```bash
node --test services/release-mirror/worker.test.mjs
```
