# Release mirror

A Cloudflare Worker that serves the latest release when GitHub can't: the
app's update check and both installers fall back to it. It holds
`latest.json`, `SHA256SUMS` and the installer in KV, and optionally the
binaries in R2.

```bash
curl -fsSL https://anicat-releases.anicat.workers.dev/install.sh | bash
```

## Deploy

```bash
cd services/release-mirror
npx wrangler login
npx wrangler kv namespace create RELEASES   # paste the id into wrangler.toml
npx wrangler deploy
```

To mirror the binaries too, enable R2, run
`npx wrangler r2 bucket create anicat-releases`, uncomment `[[r2_buckets]]`
in `wrangler.toml` and deploy again. If the URL differs from the one above,
set `ANICAT_RELEASE_MIRROR` for `publish-release.sh` and update the constant
in `UpdateChecker.swift` and both installers.

`publish-release.sh` fills it after each release. The Windows zip is attached
by CI later, so its download redirects to GitHub instead.

## Test

```bash
node --test services/release-mirror/worker.test.mjs
```
